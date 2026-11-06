import CraCore
import Foundation
import Testing

/// The command bar's ranking (Arc's ⌘T): what each source lists for the typed text, in what order,
/// and what Tab and the inline completion offer.
@MainActor
struct SuggestionEngineTests {
    /// What the engine asked the network for, and what it answers.
    final class Network: @unchecked Sendable {
        var asked: [URL] = []
        var answer: Data?
    }

    private func engine(_ f: StoreFixture, commands: [CommandBarCommand] = [], network: Network = Network()) -> SuggestionEngine {
        SuggestionEngine(store: f.store, commands: { commands }, load: { url in
            network.asked.append(url)
            return network.answer
        })
    }

    private func ids(_ r: SuggestionResult) -> [String] { r.items.map(\.id) }

    final class Flag { var up = false }

    /// What the engine reader was asked for.
    final class Reads: @unchecked Sendable { var all: [(String?, SearchEngine)] = [] }

    /// Asks the engine about `query` and waits for its answer to come in.
    private func fetch(_ e: SuggestionEngine, _ query: String) async {
        let answered = Flag()
        e.fetchSearchSuggestions(for: query) { answered.up = true }
        while !answered.up { await Task.yield() }
    }

    // MARK: Sources

    @Test func nothingTypedListsRecentTabsAndTheArchive() {
        let f = StoreFixture()
        let e = engine(f)
        let a = f.store.createTab(url: "https://a.test/", title: "Alpha")
        let b = f.store.createTab(url: "https://b.test/", title: "Beta")
        let c = f.store.createTab(url: "https://c.test/", title: "Gamma")
        f.store.archiveTab(c.id, reason: .manual)
        let r = e.suggestions(for: "  ", mode: .newTab, currentTabID: b.id)
        #expect(ids(r).contains("tab:\(a.id)") && !ids(r).contains("tab:\(b.id)"), "open tabs but the one in front")
        let archived = r.items.first { $0.id == "arch:\(c.id)" }
        #expect(archived?.subtitle.hasPrefix("Archived") == true && archived?.trailing == "Restore")
        // Tab on the empty field lists the actions (#195).
        #expect(r.items.count <= SuggestionEngine.maxRows && r.inlineCompletion == nil && r.scope == .actions)
    }

    @Test func theTypedTextIsASearchOrAnAddress() {
        let f = StoreFixture()
        let e = engine(f)
        let search = e.suggestions(for: "hello world", mode: .newTab, currentTabID: nil)
        let typed = search.items.first { $0.id == "typed" }
        #expect(typed?.kind == .search && typed?.url == "https://www.google.com/search?q=hello%20world&ie=UTF-8")
        #expect(typed?.subtitle == "Search Google" && search.query == "hello world")
        #expect(e.searchURL("hello world") == typed?.url && e.searchEngine == ChromiumSearchEngine(.google))
        let address = e.suggestions(for: "example.org/path", mode: .editURL, currentTabID: nil)
        let open = address.items.first { $0.id == "typed" }
        #expect(open?.kind == .navigate && open?.url == TypedURL.fromInput("example.org/path") && open?.subtitle == "Open URL")
        #expect(SuggestionEngine.looksLikeURL("example.org") && !SuggestionEngine.looksLikeURL("hello world"))
        #expect(SuggestionEngine.urlFromInput("example.org") == TypedURL.fromInput("example.org"))
    }

    @Test func anOpenTabLeadsAndCompletesToItsAddress() {
        let f = StoreFixture()
        let e = engine(f)
        let tab = f.store.createTab(url: "https://www.github.com/vishnu", title: "GitHub Vishnu", select: false)
        let r = e.suggestions(for: "git", mode: .newTab, currentTabID: nil)
        #expect(r.items.first?.id == "tab:\(tab.id)" && r.items.first?.trailing == "Switch to Tab", "the tab supplies the completion")
        #expect(r.items.dropFirst().first?.id == "typed", "then what was typed")
        #expect(r.inlineCompletion == "github.com/vishnu", "its whole address, as Arc completes an open tab")
        #expect(r.scope?.name == "GitHub", "Tab searches GitHub")
        #expect(r.items.first?.tabID == tab.id && r.items.first(where: { $0.id == "typed" })?.tabID == nil)
    }

    @Test func historyAndPopularDomains() {
        let f = StoreFixture()
        let e = engine(f)
        f.store.recordVisit(url: "https://news.example.com/story", title: "Big Story")
        let r = e.suggestions(for: "big st", mode: .newTab, currentTabID: nil)
        let row = r.items.first { $0.id == "hist:https://news.example.com/story" }
        #expect(row?.symbol == "clock" && row?.subtitle == "news.example.com/story" && row?.title == "Big Story")
        #expect(r.inlineCompletion == nil, "no completion for text with a space")

        let domain = e.suggestions(for: "wikip", mode: .newTab, currentTabID: nil)
        #expect(domain.items.first?.id == "top:wikipedia.org" && domain.inlineCompletion == "wikipedia.org")
        #expect(domain.items.dropFirst().first?.id == "typed")
        #expect(PopularDomains.list.contains("github.com"))
    }

    @Test func aLearnedPickRanksFirst() {
        let f = StoreFixture()
        let e = engine(f)
        f.store.recordVisit(url: "https://alpha.test/one", title: "Report one")
        f.store.recordVisit(url: "https://alpha.test/two", title: "Report two")
        f.store.recordQuerySelection(query: "Report", url: "https://alpha.test/two")
        let r = ids(e.suggestions(for: "report", mode: .newTab, currentTabID: nil))
        let one = r.firstIndex(of: "hist:https://alpha.test/one"), two = r.firstIndex(of: "hist:https://alpha.test/two")
        #expect(two != nil && (one == nil || two! < one!), "the URL picked for this text before")
    }

    @Test func commandsByNameTriggerAndUse() {
        let f = StoreFixture()
        let commands = [
            CommandBarCommand(id: "settings", name: "Settings", triggers: ["prefs"], symbol: "gear", shortcut: "⌘,"),
            CommandBarCommand(id: "clearCache", name: "Clear Cache and Refresh"),
            CommandBarCommand(id: "clearCookies", name: "Clear Cookies and Refresh"),
        ]
        let e = engine(f, commands: commands)
        let r = e.suggestions(for: "sett", mode: .newTab, currentTabID: nil)
        let settings = r.items.first
        #expect(settings?.id == "cmd:settings" && settings?.kind == .command("settings"), "a command the text names leads")
        #expect(settings?.trailing == "⌘," && settings?.symbol == "gear" && settings?.subtitle == "Command")
        #expect(r.items.dropFirst().first?.id == "typed")
        #expect(ids(e.suggestions(for: "prefs", mode: .newTab, currentTabID: nil)).contains("cmd:settings"), "found by a trigger")
        #expect(!ids(e.suggestions(for: "s", mode: .newTab, currentTabID: nil)).contains("cmd:settings"), "not from one letter")

        let clear = ids(e.suggestions(for: "clear", mode: .newTab, currentTabID: nil))
        #expect(clear.firstIndex(of: "cmd:clearCache")! < clear.firstIndex(of: "cmd:clearCookies")!, "menu order on a tie")
        for _ in 0..<3 { f.store.recordCommandUse("clearCookies") }
        let used = ids(e.suggestions(for: "clear", mode: .newTab, currentTabID: nil))
        #expect(used.firstIndex(of: "cmd:clearCookies")! < used.firstIndex(of: "cmd:clearCache")!, "the one used more")
        let generic = e.suggestions(for: "cache", mode: .newTab, currentTabID: nil).items.first { $0.id == "cmd:clearCache" }
        #expect(generic?.symbol == "command" && generic?.trailing == nil)
    }

    @Test func spacesAndFoldersToSwitchToOrMoveTo() {
        let f = StoreFixture()
        let e = engine(f)
        let work = f.store.createSpace(title: "Work", emoji: "💼", focus: false)
        let tab = f.store.createTab(url: "https://a.test/")
        let folder = f.store.createFolder(named: "Reading", in: f.space.pinnedContainerID)
        let r = e.suggestions(for: "work", mode: .newTab, currentTabID: tab.id)
        let go = r.items.first { $0.id == "space:\(work.id)" }
        #expect(go?.kind == .switchSpace(work.id) && go?.title == "Switch to Work" && go?.trailing == "💼")
        #expect(r.items.first { $0.id == "move:\(work.id)" }?.kind == .moveToSpace(work.id))
        #expect(!ids(e.suggestions(for: "work", mode: .newTab, currentTabID: nil)).contains("move:\(work.id)"), "moving needs a tab")
        let into = e.suggestions(for: "reading", mode: .newTab, currentTabID: tab.id).items.first { $0.id == "folder:\(folder.id)" }
        #expect(into?.kind == .moveToFolder(folder.id) && into?.title == "Move Tab to Reading")
    }

    @Test func incognitoListsNothingFromTheProfile() {
        let f = StoreFixture()
        let e = engine(f)
        f.store.recordVisit(url: "https://secret.test/", title: "Secretive")
        _ = f.store.createSpace(title: "Secretive Space", emoji: "🕶", focus: false)
        let window = f.store.addIncognitoWindow(frame: nil)
        f.store.activeWindowID = window.id
        let r = ids(e.suggestions(for: "secretive", mode: .newTab, currentTabID: nil))
        #expect(!r.contains("hist:https://secret.test/") && !r.contains { $0.hasPrefix("space:") })
        #expect(r.contains("typed"))
    }

    /// The app reads Chromium's engines (its default and keywords) when the bar opens; the
    /// default reader stands in with Cra's own setting.
    @Test func chromiumsEnginesAreReadOncePerOpening() {
        let f = StoreFixture()
        let wiki = ChromiumSearchEngine(id: 30, name: "Wikipedia DA", keyword: "wda", url: "https://da.wikipedia.org/w/index.php?search={searchTerms}")
        let reads = Reads()
        let e = SuggestionEngine(store: f.store, commands: { [] }, load: { _ in nil }, engines: { profile, legacy in
            reads.all.append((profile, legacy))
            return (ChromiumSearchEngine(.duckduckgo), [wiki])
        })
        let typed = e.suggestions(for: "hello", mode: .newTab, currentTabID: nil).items.first { $0.id == "typed" }
        #expect(typed?.subtitle == "Search DuckDuckGo" && typed?.url == "https://duckduckgo.com/?q=hello")
        #expect(e.suggestions(for: "wda", mode: .newTab, currentTabID: nil).scope?.name == "Wikipedia DA")
        #expect(reads.all.count == 1 && reads.all.first?.1 == f.store.settings.searchEngine)
        #expect(reads.all.first?.0 == f.store.profilePath(space: f.store.focusedSpaceID))
        e.resetIndex()
        _ = e.searchURL("again")
        #expect(reads.all.count == 2, "read again when the bar opens again")
    }

    // MARK: Scopes

    @Test func aSiteScopeSearchesThatSite() throws {
        let f = StoreFixture()
        let e = engine(f)
        let youtube = try #require(SiteSearch.all.first { $0.name == "YouTube" })
        let r = e.suggestions(for: " cats ", in: youtube)
        #expect(r.items.count == 1 && r.items.first?.url == "https://www.youtube.com/results?search_query=cats")
        #expect(r.items.first?.subtitle == "Search YouTube")
        #expect(e.suggestions(for: "  ", in: youtube).items.isEmpty)
        #expect(CommandBarScope.site(youtube).name == "YouTube" && CommandBarScope.tabs.name == TabSearchScope.name)
        #expect(e.suggestions(for: "%", mode: .newTab, currentTabID: nil).scope == .tabs)
    }

    @Test func siteSearchMatching() throws {
        #expect(SiteSearch.match("twit", completion: "twitch.tv")?.host == "twitter.com")
        #expect(SiteSearch.match("x", completion: "x.com")?.host == "x.com")
        #expect(SiteSearch.match("www.you", completion: nil)?.name == "YouTube")
        #expect(SiteSearch.match("you tube", completion: nil) == nil && SiteSearch.match("github.com/x", completion: nil) == nil)
        #expect(SiteSearch.match("www.", completion: nil) == nil)
        let maps = try #require(SiteSearch.all.first { $0.name == "Google Maps" })
        #expect(maps.searchURL("a&b c") == "https://www.google.com/maps/search/a%26b%20c")
    }

    @Test func theTabsScopeListsTheSpacesOpenTabs() {
        let f = StoreFixture()
        let e = engine(f)
        let one = f.store.createTab(url: "https://one.test/", title: "Alpha one")
        let two = f.store.createTab(url: "https://two.test/", title: "Beta two")
        let all = ids(e.suggestions(for: "", inTabsOf: f.store.focusedSpaceID, currentTabID: two.id))
        #expect(all.contains("tab:\(one.id)") && !all.contains("tab:\(two.id)"), "all but the tab in front")
        let typed = e.suggestions(for: "beta", inTabsOf: f.store.focusedSpaceID, currentTabID: nil)
        #expect(typed.items.first?.id == "tab:\(two.id)" && typed.items.first?.spaceID == f.store.focusedSpaceID)
        #expect(!ids(typed).contains("tab:\(one.id)"), "only what matches")
    }

    // MARK: Search suggestions

    @Test func theEnginesSuggestionsFillTheRows() async {
        let f = StoreFixture()
        let network = Network()
        network.answer = Data(#"["cat",["cat videos","cats","https://cat.example/"],[],[],{"google:suggesttype":["QUERY","QUERY","NAVIGATION"]}]"#.utf8)
        let e = engine(f, network: network)
        await fetch(e, " cat ")
        #expect(network.asked == [e.searchEngine.suggestURL("cat")].compactMap { $0 })
        let r = e.suggestions(for: "cat", mode: .newTab, currentTabID: nil)
        let search = r.items.first { $0.id == "sugg:cat videos" }
        #expect(search?.kind == .search && search?.url == e.searchEngine.searchURL("cat videos"))
        let site = r.items.first { $0.id == "sugg:https://cat.example/" }
        #expect(site?.title == "cat.example" && site?.kind == .history)

        e.resetIndex()
        #expect(!ids(e.suggestions(for: "cat", mode: .newTab, currentTabID: nil)).contains("sugg:cat videos"), "forgotten on close")
        network.answer = nil
        await fetch(e, "dog")
        #expect(!ids(e.suggestions(for: "dog", mode: .newTab, currentTabID: nil)).contains { $0.hasPrefix("sugg:") }, "no answer, no rows")

        f.store.settings.searchSuggestions = false
        let asked = network.asked.count
        e.fetchSearchSuggestions(for: "bird") {}
        e.fetchSearchSuggestions(for: "https://x.test/") {}
        #expect(network.asked.count == asked, "turned off in Settings: nothing is asked")
    }

    @Test func suggestParsing() {
        let calc = Data(#"["1+1",["= 2","one"],[],[],{"google:suggesttype":["CALCULATOR","QUERY"]}]"#.utf8)
        #expect(SearchSuggestions.parse(calc) == [SearchSuggestions.Item(text: "one", url: nil)])
        #expect(SearchSuggestions.parse(Data(#"["q",["a","b"]]"#.utf8)).map(\.text) == ["a", "b"], "plain OpenSearch")
        #expect(SearchSuggestions.parse(Data("nonsense".utf8)).isEmpty)
        #expect(SearchSuggestions.acceptLanguage(["da-DK", "en-US", "en"]) == "da-DK,en-US;q=0.8,en;q=0.6")
    }

    // MARK: Field and Return

    @Test func whatTheFieldShowsAndWhatReturnOpens() throws {
        let f = StoreFixture()
        let e = engine(f, commands: [CommandBarCommand(id: "settings", name: "Settings")])
        f.store.recordVisit(url: "https://www.example.com/page/", title: "Example page")
        let r = e.suggestions(for: "exa", mode: .newTab, currentTabID: nil)
        let typed = try #require(r.items.first { $0.id == "typed" })
        #expect(typed.fieldText(typed: "exa") == "exa", "the typed row shows what was typed")
        let page = try #require(r.items.first { $0.id == "hist:https://www.example.com/page/" })
        #expect(page.fieldText(typed: "exa") == "example.com/page", "a page shows its address")
        let command = try #require(e.suggestions(for: "sett", mode: .newTab, currentTabID: nil).items.first { $0.id == "cmd:settings" })
        #expect(command.fieldText(typed: "sett") == "Settings", "a command its name")

        let completing = e.suggestions(for: "wikip", mode: .newTab, currentTabID: nil)
        let typedIndex = try #require(completing.items.firstIndex { $0.id == "typed" })
        #expect(completing.commit(at: 0, typed: "wikip", scope: nil)?.typed == "wikip", "the completing row goes to its own page")
        var onTop = completing
        onTop.items.swapAt(0, typedIndex)
        #expect(onTop.commit(at: 0, typed: "wikip", scope: nil)?.typed == "wikipedia.org", "the typed row on top goes to the completion")
        #expect(completing.commit(at: 9, typed: "wikip", scope: nil).map { $0.row == nil && $0.typed == "wikip" } == true)
        #expect(SuggestionResult().commit(at: 0, typed: "x", scope: .tabs) == nil, "the tabs scope with nothing to switch to")
    }

    // MARK: Scoring and text

    @Test func textScores() {
        let e = engine(StoreFixture())
        #expect(e.textScore("git", title: "GitHub", url: "https://x.test/") == 100, "title prefix")
        #expect(e.textScore("hub", title: "Git Hub", url: "https://x.test/") == 85, "a word's prefix")
        #expect(e.textScore("hub", title: "GitHub", url: "https://x.test/") == 65, "inside the title")
        let loose = e.textScore("gthb", title: "github", url: "https://x.test/")
        #expect(loose > 25 && loose < 50, "scattered letters")
        #expect(e.textScore("exa", title: "Z", url: "https://www.example.com/") == 95, "the host's start")
        #expect(e.textScore("ample", title: "Z", url: "https://example.com/") == 70, "inside the host")
        #expect(e.textScore("path", title: "Z", url: "https://x.test/path") == 55, "the address")
        #expect(e.textScore("git hub", title: "GitHub repo hub", url: "https://x.test/") == 75, "every word")
        #expect(e.textScore("git zzz", title: "GitHub", url: "https://x.test/") == 15, "half the words")
        #expect(e.textScore("git hub", title: "Git hub", url: "https://x.test/") == 95, "the phrase starts the title")
    }

    @Test func addressesAndAgesAsTheBarWritesThem() {
        #expect(SuggestionEngine.humanURL("https://www.example.com/") == "example.com")
        #expect(SuggestionEngine.humanURL("http://a.test/x") == "a.test/x")
        let long = SuggestionEngine.humanURL("https://a.test/" + String(repeating: "x", count: 100))
        #expect(long.count == 68 && long.hasSuffix("…"))

        let now = Date()
        #expect(SuggestionEngine.relative(now.addingTimeInterval(-7200), now: now).contains("2"))
    }
}
