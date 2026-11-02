import CraCore
import Foundation
import Testing

/// The store's files, windows, tabs, spaces, profiles and history, on a data folder of its own.
@MainActor
struct SidebarStoreTests {
    // MARK: Files

    @Test func aFreshFolderStartsWithOneSpaceAndOneWindow() {
        let f = StoreFixture()
        #expect(f.store.orderedSpaces.map(\.title) == ["Personal"])
        #expect(f.store.prefs.windows.count == 1)
        #expect(f.store.activeWindowID == f.store.prefs.windows[0].id)
        #expect(f.store.lastNormalWindowID == f.store.activeWindowID)
        #expect(f.store.selectedTab == nil)
        #expect(f.sound)
    }

    @Test func whatIsSavedLoadsBack() {
        let f = StoreFixture()
        let tab = f.store.createTab(url: "https://a.test/", title: "A")
        f.store.recordVisit(url: "https://a.test/", title: "A")
        f.store.recordCommandUse("newTab")
        f.store.settings.newTabsAtTop = false
        let other = f.store.createSpace(title: "Work", emoji: "💼", focus: false)
        let g = f.reopened()
        #expect(g.store.item(tab.id)?.tab?.url == "https://a.test/")
        #expect(g.store.selectedTabID == tab.id)
        #expect(g.store.orderedSpaces.map(\.id) == [f.space.id, other.id])
        #expect(g.store.history["https://a.test/"]?.visitCount == 1)
        #expect(g.store.ranking.commandUsage["newTab"] == 1)
        #expect(g.store.settings.newTabsAtTop == false)
        for name in ["sidebar.json", "archive.json", "windows.json", "settings.json", "history.json", "commandbar.json"] {
            #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test func savingWritesTheArchiveOnlyWhenItChanged() {
        let f = StoreFixture()
        let tab = f.store.createTab(url: "https://a.test/")
        f.store.archiveTab(tab.id, reason: .manual)
        f.store.save()
        f.store.saveAll()
        let g = f.reopened()
        #expect(g.store.archive.map(\.id) == [tab.id])
    }

    @Test func aMissingToolbarMarkTakesArcsToolbar() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-core-toolbar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let f = StoreFixture(directory: dir, arcShowsToolbar: true)
        #expect(f.store.settings.showToolbar && f.store.settings.toolbarDefaultMigrated)
        let fresh = StoreFixture(arcShowsToolbar: true)
        #expect(!fresh.store.settings.showToolbar, "a fresh install's settings are already migrated")
    }

    @Test func anUnreadableFileIsSetAsideAndReported() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-core-corrupt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "broken-\(UUID().uuidString).json"
        try? Data("{ not json".utf8).write(to: dir.appendingPathComponent(name))
        let faults = Faults()
        let before = CoreLog.fault
        CoreLog.fault = { message in faults.add(message) }
        defer { CoreLog.fault = before }
        let loaded = JSONStore<[String]>(name, in: dir).load(or: { ["fallback"] })
        #expect(loaded == ["fallback"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".corrupt").path))
        JSONStore<[Double]>(name, in: dir).saveNow([.nan])
        JSONStore<[String]>(name, in: dir.appendingPathComponent("missing", isDirectory: true)).saveNow(["x"])
        #expect(faults.lines.filter { $0.contains(name) }.count == 3)
    }

    @Test func aSavedFileKeepsItsPreviousVersion() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-core-bak-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = JSONStore<[String]>("list.json", in: dir)
        file.saveNow(["one"])
        file.save(["two"], delay: 60)
        file.saveNow(["three"])
        #expect(file.load(or: { [] }) == ["three"])
        #expect(JSONStore<[String]>("list.json.bak", in: dir).load(or: { [] }) == ["one"])
    }

    final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: Repair

    @Test func repairPutsABrokenTreeRight() {
        var doc = SidebarDocument.fresh()
        let space = doc.spaces[0]
        var pinned = doc.items.first { $0.id == space.pinnedContainerID }!
        pinned.children = [UUID()]
        let orphan = SidebarItem.tab("https://orphan.test/", parent: UUID())
        var ghost = SidebarItem.container(.today(spaceID: UUID()))
        let ghostTab = SidebarItem.tab("https://ghost.test/", parent: ghost.id)
        ghost.children = [ghostTab.id]
        doc.items = doc.items.filter { $0.id != space.favoritesContainerID && $0.id != space.pinnedContainerID }
            + [pinned, orphan, ghost, ghostTab]
        doc.spaces[0].profileID = UUID()
        // A space the order forgot.
        let lost = Self.space(titled: "Lost")
        doc.spaces.append(lost.space)
        doc.items += lost.containers
        let f = StoreFixture.loading(doc)
        #expect(f.store.item(space.favoritesContainerID)?.container != nil, "a missing container is made again")
        #expect(f.store.space(space.id)?.profileID == nil, "a profile that is gone falls back to Default")
        #expect(f.store.item(space.pinnedContainerID)?.children.isEmpty == true, "a child that is gone is dropped")
        #expect(f.store.item(orphan.id)?.parentID == space.todayContainerID, "an orphan lands in Today")
        #expect(f.store.item(ghostTab.id) == nil && f.store.item(ghost.id) == nil, "a gone space's tabs go with it")
        #expect(f.store.spaceOrder == [space.id, lost.space.id])
        #expect(f.sound)
    }

    @Test func aFileWithoutSpacesStartsFresh() {
        let f = StoreFixture.loading(SidebarDocument(spaceOrder: [], spaces: [], items: []))
        #expect(f.store.orderedSpaces.count == 1 && f.sound)
    }

    @Test func sharedFavoritesAreSplitBetweenTheSpaces() {
        var doc = SidebarDocument.fresh()
        let first = doc.spaces[0]
        let second = Self.space(titled: "Work")
        var shared = SidebarItem.container(.favorites(spaceID: ContainerKind.sharedFavoritesSpaceID))
        var folder = SidebarItem.folder("Tools", parent: shared.id)
        let mail = SidebarItem.tab("https://mail.test/", parent: shared.id)
        let docs = SidebarItem.tab("https://docs.test/", parent: folder.id)
        folder.children = [docs.id]
        shared.children = [mail.id, folder.id]
        doc.spaces.append(second.space)
        doc.spaceOrder.append(second.space.id)
        doc.items += second.containers + [shared, folder, mail, docs]
        doc.favoritesContainerID = shared.id
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-core-shared-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        JSONStore<SidebarDocument>("sidebar.json", in: dir).saveNow(doc)
        JSONStore<WindowPrefs>("windows.json", in: dir).saveNow(WindowPrefs(
            expandedFolders: [folder.id],
            windows: [WindowSession(focusedSpaceID: first.id, selectedTabPerSpace: [second.space.id: mail.id])]))
        let f = StoreFixture(directory: dir)
        #expect(f.favorites(first) == [mail.id, folder.id], "the focused space keeps the original tabs")
        let copies = f.favorites(second.space)
        #expect(copies.count == 2 && !copies.contains(mail.id))
        #expect(f.store.item(copies[0])?.tab?.url == "https://mail.test/")
        #expect(f.store.tabs(under: copies[1]).map { $0.tab?.url } == ["https://docs.test/"])
        #expect(f.store.window().selectedTabPerSpace[second.space.id] == copies[0], "an open favorite stays open as the copy")
        #expect(f.store.isExpanded(copies[1]), "an open folder's copy is open")
        #expect(f.store.item(shared.id) == nil && f.sound)
    }

    static func space(titled title: String) -> (space: Space, containers: [SidebarItem]) {
        let id = UUID()
        let fav = SidebarItem.container(.favorites(spaceID: id))
        let pinned = SidebarItem.container(.pinned(spaceID: id))
        let today = SidebarItem.container(.today(spaceID: id))
        let space = Space(id: id, title: title, emoji: "🧪", theme: SpaceTheme.presets[1], favoritesContainerID: fav.id,
                          pinnedContainerID: pinned.id, todayContainerID: today.id, createdAt: Date())
        return (space, [fav, pinned, today])
    }

    // MARK: Windows

    @Test func windowsComeAndGoButTheLastStays() {
        let f = StoreFixture()
        let first = f.store.window()
        let second = f.store.addWindow(spaceID: f.space.id, frame: "{{0, 0}, {800, 600}}")
        #expect(f.store.window(second.id).frame == "{{0, 0}, {800, 600}}")
        #expect(f.store.window(UUID()).id == first.id, "a window that is gone reads as the active one")
        f.store.updateWindow(second.id) { $0.sidebarVisible = false }
        f.store.updateWindow(UUID()) { $0.sidebarVisible = false }
        #expect(!f.store.window(second.id).sidebarVisible && f.store.window(first.id).sidebarVisible)
        f.store.activeWindowID = second.id
        f.store.removeWindow(second.id)
        #expect(f.store.prefs.windows.map(\.id) == [first.id])
        #expect(f.store.activeWindowID == first.id)
        f.store.removeWindow(first.id)
        #expect(f.store.prefs.windows.count == 1, "the last window only hides")
    }

    @Test func anIncognitoWindowKeepsItsTabsToItself() {
        let f = StoreFixture()
        let normal = f.store.createTab(url: "https://normal.test/")
        let w = f.store.addIncognitoWindow(frame: nil)
        let sid = w.focusedSpaceID!
        #expect(f.store.isIncognito(space: sid) && f.store.space(sid)?.theme == SpaceTheme.incognito)
        #expect(f.store.pagedSpaces(window: w.id).map(\.id) == [sid])
        #expect(f.store.pagedSpaces(window: nil).map(\.id) == [f.space.id])
        #expect(!f.store.hidesSpaceHeader(sid))
        let secret = f.store.createTab(url: "https://secret.test/", window: w.id)
        #expect(f.store.isIncognito(item: secret.id) && f.store.selectedTabID(window: w.id) == secret.id)
        #expect(f.store.profileTabs(window: w.id).map(\.id) == [secret.id])
        #expect(f.store.profileTabs(window: nil).map(\.id) == [normal.id])
        #expect(!f.store.document.items.contains { $0.id == secret.id }, "incognito tabs never reach the disk")
        #expect(f.store.ranking.recentlySwitchedToTabs[secret.id] == nil)
        #expect(f.store.profilePath(item: secret.id) == nil && f.store.profileDirectoryName(item: secret.id) == "Default")
        f.store.setThemeColor(secret.id, "#000000")
        #expect(f.store.item(secret.id)?.tab?.themeColor == nil)

        // In front, it sends normal tabs to the last normal window and takes nothing in.
        f.store.activeWindowID = w.id
        #expect(f.store.lastNormalWindowID != w.id)
        f.store.selectTab(normal.id)
        #expect(f.store.window(f.store.lastNormalWindowID).selectedTabPerSpace[f.space.id] == normal.id)
        f.store.selectTab(normal.id, window: w.id)
        #expect(f.store.selectedTabID(window: w.id) == secret.id)
        f.store.moveItem(normal.id, to: f.store.space(sid)!.todayContainerID, index: nil)
        #expect(f.store.spaceID(ofItem: normal.id) == f.space.id)
        f.store.focusSpace(f.space.id, window: w.id)
        #expect(f.store.focusedSpaceID(window: w.id) == sid)
        f.store.recordQuerySelection(query: "secret", url: "https://secret.test/")
        #expect(f.store.ranking.queriesToSelected.isEmpty)
        f.store.createSpace(title: "Work", emoji: "💼")
        #expect(f.store.focusedSpaceID(window: w.id) == sid, "a new space doesn't take over an incognito window")
        #expect(f.store.createLiveFolder(.github, inSpace: sid) == nil)

        f.store.removeWindow(w.id)
        #expect(f.store.item(secret.id) == nil && f.store.space(sid) == nil && !f.store.isIncognito(space: sid))
        #expect(f.store.activeWindowID == f.store.lastNormalWindowID)
        #expect(f.sound)
    }

    // MARK: Tabs

    @Test func newTabsGoWhereTheSettingsSay() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        #expect(f.today() == [b.id, a.id], "new tabs at the top")
        #expect(f.store.item(b.id)?.tab?.activeTabBeforeCreationID == a.id)
        f.store.settings.newTabsAtTop = false
        let c = f.store.createTab(url: "https://c.test/", select: false)
        #expect(f.today() == [b.id, a.id, c.id])
        #expect(f.store.item(c.id)?.isUnread == true && f.store.selectedTabID == b.id)
        let p1 = f.store.createTab(url: "https://p1.test/", pinned: true)
        let p2 = f.store.createTab(url: "https://p2.test/", pinned: true)
        #expect(f.pinned() == [p1.id, p2.id])
        #expect(f.store.isPinned(p1.id) && !f.store.isFavorite(p1.id) && !f.store.isPinned(a.id))
        let at = f.store.createTab(url: "https://at.test/", parent: f.space.todayContainerID, index: 1)
        #expect(f.today()[1] == at.id)
        #expect(f.store.visibleTabs(in: f.space.id).map(\.id) == [p1.id, p2.id] + f.today())
        #expect(f.store.listedTabIDs(in: f.space.id) == [p1.id, p2.id] + f.today())
        #expect(f.store.allTabs().count == 6)
        #expect(f.store.visibleTabs(in: UUID()).isEmpty && f.store.listedTabIDs(in: UUID()).isEmpty)
        #expect(f.sound)
    }

    @Test func selectingATabMarksItReadAndRemembersIt() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/", select: false)
        f.clock.advance(by: 10)
        f.store.selectTab(a.id)
        #expect(f.store.item(a.id)?.isUnread == false)
        #expect(f.store.item(a.id)?.tab?.timeLastActiveAt == f.clock.now)
        #expect(f.store.ranking.recentlySwitchedToTabs[a.id]?.count == 1)
        for _ in 0..<12 { f.store.selectTab(a.id) }
        #expect(f.store.ranking.recentlySwitchedToTabs[a.id]?.count == 10, "ten switches are remembered")
        #expect(f.store.isSelected(a.id, window: nil) && f.store.isSelected(a.id, inSpace: f.space.id, window: nil))
        f.store.selectTab(nil)
        #expect(f.store.selectedTabID == nil && !f.store.isSelected(a.id, window: nil))
        f.store.selectTab(f.space.todayContainerID)
        #expect(f.store.selectedTabID == nil, "only tabs are selected")
    }

    @Test func pagesReportingTheSameThingWriteNothing() {
        let f = StoreFixture()
        let tab = f.store.createTab(url: "https://a.test/", title: "A")
        f.store.updateTab(tab.id, url: "https://a.test/page", title: "Page")
        #expect(f.store.item(tab.id)?.tab?.url == "https://a.test/page")
        #expect(f.store.item(tab.id)?.tab?.savedURL == "https://a.test/page")
        #expect(f.store.item(tab.id)?.tab?.savedTitle == "Page")
        let revision = f.store.revision
        f.store.updateTab(tab.id, url: "https://a.test/page", title: "Page")
        f.store.updateTab(tab.id, url: "about:blank")
        f.store.updateTab(f.space.todayContainerID, url: "https://x.test/")
        #expect(f.store.revision == revision && f.store.item(tab.id)?.tab?.url == "https://a.test/page")

        let empty = f.store.createTab(url: "")
        #expect(f.store.item(empty.id)?.isEmptyTab == true)
        let before = f.store.revision
        f.store.updateTab(empty.id, url: "https://b.test/")
        #expect(f.store.revision == before + 1, "a pane that gets its first page changes the layout")
    }

    @Test func aPinnedTabKeepsItsHome() {
        let f = StoreFixture()
        let tab = f.store.createTab(url: "https://home.test/", pinned: true)
        f.store.updateTab(tab.id, url: "https://home.test/elsewhere")
        #expect(f.store.item(tab.id)?.tab?.savedURL == "https://home.test/")
        #expect(f.store.resetPinnedTab(tab.id) == "https://home.test/")
        #expect(f.store.item(tab.id)?.tab?.url == "https://home.test/")
        f.store.updateTab(tab.id, url: "https://home.test/new-home")
        f.store.setPinnedHomeToCurrent(tab.id)
        #expect(f.store.item(tab.id)?.tab?.savedURL == "https://home.test/new-home")

        // Edit Pinned URL: on its home page the tab goes along; navigated away it stays.
        #expect(f.store.setPinnedURL(tab.id, to: "https://other.test/"))
        #expect(f.store.item(tab.id)?.tab?.url == "https://other.test/" && f.store.item(tab.id)?.tab?.savedTitle == "")
        f.store.updateTab(tab.id, url: "https://other.test/away")
        #expect(f.store.setPinnedURL(tab.id, to: "https://third.test/"))
        #expect(f.store.item(tab.id)?.tab?.url == "https://other.test/away" && f.store.item(tab.id)?.tab?.savedURL == "https://third.test/")

        let today = f.store.createTab(url: "https://today.test/")
        #expect(f.store.resetPinnedTab(today.id) == nil && !f.store.setPinnedURL(today.id, to: "https://x.test/"))
    }

    @Test func aTabsSmallStateIsKept() {
        let f = StoreFixture()
        let tab = f.store.createTab(url: "https://a.test/")
        f.store.markUnread(tab.id)
        #expect(f.store.item(tab.id)?.isUnread == true)
        f.store.markUnread(tab.id, false)
        f.store.setMuted(tab.id, true)
        #expect(f.store.item(tab.id)?.tab?.muted == true)
        f.store.rename(tab.id, to: "  Mine  ")
        #expect(f.store.item(tab.id)?.title == "Mine")
        f.store.rename(tab.id, to: "   ")
        #expect(f.store.item(tab.id)?.title == nil)
        f.store.setThemeColor(tab.id, "#112233")
        #expect(f.store.item(tab.id)?.tab?.themeColor == "#112233")
        f.store.setCustomIcon("icon-key", for: tab.id)
        #expect(f.store.item(tab.id)?.tab?.customIconKey == "icon-key")
        f.store.setTileColor("#FF0000", for: [tab.id, f.space.todayContainerID])
        #expect(f.store.item(tab.id)?.tab?.tileColor == "#FF0000")
    }

    @Test func aDuplicateOpensRightBelow() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/", title: "A")
        let b = f.store.createTab(url: "https://b.test/")
        let copy = f.store.duplicateTab(a.id)
        #expect(f.today() == [b.id, a.id, copy!.id])
        #expect(copy?.tab?.url == "https://a.test/" && f.store.selectedTabID == copy?.id)
        #expect(f.store.duplicateTab(f.space.todayContainerID) == nil)
    }

    @Test func theTabSwitcherListsRecentTabsFirst() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        f.clock.advance(by: 1)
        let b = f.store.createTab(url: "https://b.test/")
        f.clock.advance(by: 1)
        f.store.selectTab(a.id)
        _ = f.store.createTab(url: "https://never.test/", select: false)
        #expect(f.store.recentTabs(in: f.space.id, limit: 5) == [a.id, b.id])
        #expect(f.store.recentTabs(in: f.space.id, limit: 1) == [a.id])
    }

    @Test func importHelpersPlaceWhatTheyAreGiven() {
        let f = StoreFixture()
        let tab = SidebarItem.tab("https://imported.test/", parent: nil)
        f.store.insertItem(tab, into: f.space.pinnedContainerID, at: 5)
        #expect(f.pinned() == [tab.id] && f.store.item(tab.id)?.parentID == f.space.pinnedContainerID)
        let revision = f.store.revision
        f.store.touchAfterImport()
        #expect(f.store.revision == revision + 1)
        let older = ArchivedItem(archivedAt: f.clock.now.addingTimeInterval(-100), reason: .manual, sourceSpaceID: nil, wasPinned: false,
                                 item: SidebarItem.tab("https://old.test/", parent: nil))
        let newer = ArchivedItem(archivedAt: f.clock.now, reason: .auto, sourceSpaceID: nil, wasPinned: false,
                                 item: SidebarItem.tab("https://new.test/", parent: nil))
        f.store.appendArchived(older)
        f.store.appendArchived(newer)
        #expect(f.store.archive.map(\.id) == [newer.id, older.id])
        f.store.archiveLittleWindowPage(url: "https://little.test/", title: "Little")
        #expect(f.store.archive.first?.fromLittleWindow == true && f.store.archive.first?.item.tab?.url == "https://little.test/")
    }

    @Test func theLibraryKeepsTwoThousandPages() {
        let f = StoreFixture()
        for i in 0..<2001 { f.store.archiveLittleWindowPage(url: "https://p\(i).test/", title: "") }
        #expect(f.store.archive.count == 2000 && f.store.archive.first?.item.tab?.url == "https://p2000.test/")
    }

    @Test func aBrokenTreeIsReported() {
        let f = StoreFixture()
        let stray = SidebarItem.tab("https://stray.test/", parent: nil)
        f.store.insertItem(stray, into: UUID(), at: nil)
        let loose = SidebarItem.folder("Loose", parent: nil)
        f.store.insertItem(loose, into: f.space.pinnedContainerID, at: nil)
        f.store.insertItem(loose, into: f.space.todayContainerID, at: nil)
        f.store.updateWindow(nil) { $0.selectedTabPerSpace[UUID()] = f.space.todayContainerID }
        let problems = f.store.integrityProblems()
        #expect(problems.contains { $0.contains("points at missing parent") })
        #expect(problems.contains { $0.contains("is listed by both") || $0.contains("but points at") })
        #expect(problems.contains { $0.contains("lives elsewhere") })
    }

    // MARK: Spaces

    @Test func spacesAreMadeOrderedAndFocused() {
        let f = StoreFixture()
        let personal = f.space
        #expect(f.store.hidesSpaceHeader(personal.id) == false)
        f.store.settings.showSpaceHeaderOnSingleSpace = false
        #expect(f.store.hidesSpaceHeader(personal.id))
        let work = f.store.createSpace(title: "Work", emoji: "💼")
        #expect(f.store.focusedSpaceID == work.id && work.theme == SpaceTheme.presets[1 % SpaceTheme.presets.count])
        let play = f.store.createSpace(title: "Play", emoji: "🎮", theme: SpaceTheme.incognito, focus: false)
        #expect(f.store.focusedSpaceID == work.id && play.theme == SpaceTheme.incognito)
        #expect(!f.store.hidesSpaceHeader(personal.id))
        f.store.focusSpace(offset: 1)
        #expect(f.store.focusedSpaceID == play.id)
        f.store.focusSpace(offset: 1)
        #expect(f.store.focusedSpaceID == personal.id, "paging wraps around")
        f.store.focusSpace(offset: -1)
        #expect(f.store.focusedSpaceID == play.id)
        f.store.focusSpace(UUID())
        #expect(f.store.focusedSpaceID == play.id)
        f.store.moveSpace(play.id, to: 0)
        #expect(f.store.spaceOrder == [play.id, personal.id, work.id])
        f.store.moveSpace(UUID(), to: 0)
        var renamed = work
        renamed.title = "Office"
        f.store.updateSpace(renamed)
        #expect(f.store.space(work.id)?.title == "Office")
        f.store.updateSpace(StoreFixture.loose)
        #expect(f.store.space(StoreFixture.loose.id) == nil)
    }

    @Test func deletingASpaceArchivesItsTabs() {
        let f = StoreFixture()
        let personal = f.space
        let work = f.store.createSpace(title: "Work", emoji: "💼")
        let tab = f.store.createTab(url: "https://work.test/")
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        let folder = f.store.createFolder(named: "Docs", in: work.pinnedContainerID)
        let inFolder = f.store.createTab(url: "https://doc.test/", parent: folder.id)
        f.store.deleteSpace(work.id)
        #expect(f.store.space(work.id) == nil && f.store.spaceOrder == [personal.id])
        #expect(Set(f.store.archive.map(\.id)) == [tab.id, pinned.id, inFolder.id])
        #expect(f.store.archive.allSatisfy { $0.reason == .spaceDeleted })
        #expect(f.store.item(folder.id) == nil && f.store.focusedSpaceID == personal.id)
        f.store.deleteSpace(personal.id)
        #expect(f.store.space(personal.id) != nil, "the last space stays")
        #expect(f.sound)
    }

    @Test func aSpaceCanBecomeAFolder() {
        let f = StoreFixture()
        let personal = f.space
        let work = f.store.createSpace(title: "Work", emoji: "💼")
        let tab = f.store.createTab(url: "https://work.test/")
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        let live = f.store.createLiveFolder(.github, inSpace: work.id)!
        let folder = f.store.exportSpace(work.id, intoFolderIn: personal.id)
        #expect(folder?.title == "Work" && f.pinned(personal).first == folder?.id)
        #expect(Set(f.store.children(of: folder!.id).map(\.id)) == [tab.id, pinned.id])
        #expect(f.store.item(live.id) == nil && f.store.space(work.id) == nil)
        #expect(f.store.focusedSpaceID == personal.id)
        #expect(f.store.exportSpace(personal.id, intoFolderIn: personal.id) == nil)
        #expect(f.sound)
    }

    // MARK: Profiles

    @Test func profilesKeepSpacesApart() {
        let f = StoreFixture()
        let work = f.store.createProfile(name: "Work")
        f.store.renameProfile(work.id, to: "Office")
        f.store.renameProfile(work.id, to: "")
        #expect(f.store.profile(work.id)?.name == "Office" && f.store.profile(nil) == nil)
        let tab = f.store.createTab(url: "https://a.test/")
        #expect(f.store.profilePath(item: tab.id) == nil && f.store.profileDirectoryName(space: f.space.id) == "Default")
        f.store.setProfile(work.id, forSpace: f.space.id)
        f.store.setProfile(UUID(), forSpace: f.space.id)
        #expect(f.store.space(f.space.id)?.profileID == work.id)
        #expect(f.store.spaces(usingProfile: work.id).map(\.id) == [f.space.id])
        #expect(f.store.profileDirectoryName(item: tab.id) == work.directoryName)
        #expect(f.store.profilePath(item: tab.id) == f.store.chromiumCache.appendingPathComponent(work.directoryName, isDirectory: true).path)
        #expect(f.store.profileDirectoryName(item: UUID()) == "Default")
        f.store.deleteProfile(work.id)
        #expect(f.store.profile(work.id) != nil && f.deletedProfiles.names.isEmpty, "a profile in use stays")
        f.store.setProfile(nil, forSpace: f.space.id)
        f.store.deleteProfile(work.id)
        #expect(f.store.profiles.isEmpty && f.deletedProfiles.names == [work.directoryName])
    }

    // MARK: History and ranking

    @Test func visitsAndPicksAreCounted() {
        let f = StoreFixture()
        f.store.recordVisit(url: "cra://settings", title: "Settings")
        #expect(f.store.history.isEmpty)
        f.store.recordVisit(url: "https://a.test/", title: "A")
        f.clock.advance(by: 5)
        f.store.recordVisit(url: "https://a.test/", title: "")
        #expect(f.store.history["https://a.test/"]?.visitCount == 2)
        #expect(f.store.history["https://a.test/"]?.title == "A" && f.store.history["https://a.test/"]?.lastVisit == f.clock.now)
        f.store.recordQuerySelection(query: "  GitHub ", url: "https://github.com/")
        f.store.recordQuerySelection(query: "   ", url: "https://x.test/")
        #expect(f.store.ranking.queriesToSelected == ["github": "https://github.com/"])
        for i in 0..<501 { f.store.recordQuerySelection(query: "q\(i)", url: "https://q.test/") }
        #expect(f.store.ranking.queriesToSelected.count == 500)
        f.store.recordCommandUse("archive")
        f.store.recordCommandUse("archive")
        #expect(f.store.ranking.commandUsage["archive"] == 2)
    }
}

extension StoreFixture {
    /// A store whose sidebar.json is `doc`.
    static func loading(_ doc: SidebarDocument) -> StoreFixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-core-load-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        JSONStore<SidebarDocument>("sidebar.json", in: dir).saveNow(doc)
        return StoreFixture(directory: dir)
    }

    /// A space no store knows.
    static let loose = Space(id: UUID(), title: "Loose", emoji: "", theme: SpaceTheme.presets[0], favoritesContainerID: UUID(),
                             pinnedContainerID: UUID(), todayContainerID: UUID(), createdAt: Date())
}
