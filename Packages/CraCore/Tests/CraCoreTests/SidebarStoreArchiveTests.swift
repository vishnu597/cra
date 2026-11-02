import CraCore
import Foundation
import Testing

/// Closing, restoring and auto-archiving tabs, and live folders filling themselves.
@MainActor
struct SidebarStoreArchiveTests {
    // MARK: Archive

    @Test func closingGoesBackToWhereYouCameFrom() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        f.store.archiveTab(b.id, reason: .manual)
        #expect(f.store.selectedTabID == a.id, "back to the tab it was opened from")
        #expect(f.store.archive.first?.id == b.id && f.store.archive.first?.reason == .manual)
        let c = f.store.createTab(url: "https://c.test/")
        f.store.archiveTab(a.id, reason: .manual)
        f.store.archiveTab(c.id, reason: .manual)
        #expect(f.store.selectedTabID == nil && f.today().isEmpty, "nothing left to open")
        let d = f.store.createTab(url: "https://d.test/")
        let e = f.store.createTab(url: "https://e.test/")
        f.store.archiveTab(d.id, reason: .manual)
        f.store.selectTab(e.id)
        f.store.archiveTab(e.id, reason: .manual)
        #expect(f.store.selectedTabID == nil)
        f.store.archiveTab(f.space.todayContainerID, reason: .manual)
        #expect(f.store.item(f.space.todayContainerID) != nil)
    }

    @Test func closingFallsBackToTheTopOfToday() {
        let f = StoreFixture()
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        let a = f.store.createTab(url: "https://a.test/")
        f.store.archiveTab(pinned.id, reason: .manual)
        f.store.selectTab(a.id)
        let b = f.store.createTab(url: "https://b.test/", select: false)
        f.store.archiveTab(a.id, reason: .manual)
        #expect(f.store.selectedTabID == b.id)
        let p2 = f.store.createTab(url: "https://p2.test/", pinned: true, select: false)
        f.store.archiveTab(b.id, reason: .manual)
        #expect(f.store.selectedTabID == p2.id, "with Today empty, the first tab in the space")
    }

    @Test func anEmptyPaneLeavesNothingInTheLibrary() {
        let f = StoreFixture()
        let empty = f.store.createTab(url: "")
        f.store.archiveTab(empty.id, reason: .manual)
        #expect(f.store.archive.isEmpty && f.store.item(empty.id) == nil)
    }

    @Test func restoringPutsATabBackWhereItWas() {
        let f = StoreFixture()
        let today = f.store.createTab(url: "https://today.test/")
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        let other = f.store.createTab(url: "https://other.test/", pinned: true)
        let folder = f.store.createFolder(named: "Box", in: f.space.pinnedContainerID)
        let x = f.store.createTab(url: "https://x.test/", parent: folder.id)
        let y = f.store.createTab(url: "https://y.test/", parent: folder.id)
        f.store.archiveTab(today.id, reason: .manual)
        f.store.archiveTab(pinned.id, reason: .manual)
        f.store.archiveTab(x.id, reason: .manual)
        #expect(f.store.archive.first?.sourceFolderID == folder.id && f.store.archive.first?.sourceIndex == 1)

        #expect(f.store.reopenLastArchived()?.id == x.id)
        #expect(f.store.item(folder.id)?.children == [y.id, x.id] && f.store.selectedTabID == x.id)
        f.store.restoreArchived(pinned.id, select: false)
        #expect(f.pinned().first == other.id && f.pinned().last == pinned.id, "a pinned tab goes back to the end of pinned")
        f.store.restoreArchived(today.id)
        #expect(f.today().first == today.id && f.store.selectedTabID == today.id)
        #expect(f.store.item(today.id)?.isUnread == false)
        #expect(f.store.restoreArchived(UUID()) == nil)
        #expect(f.store.archive.isEmpty && f.store.reopenLastArchived() == nil)
        #expect(f.sound)
    }

    @Test func aTabFromADeletedSpaceComesBackInTheFocusedOne() {
        let f = StoreFixture()
        let personal = f.space
        let work = f.store.createSpace(title: "Work", emoji: "💼")
        let tab = f.store.createTab(url: "https://work.test/")
        f.store.deleteSpace(work.id)
        f.store.restoreArchived(tab.id)
        #expect(f.store.spaceID(ofItem: tab.id) == personal.id)
    }

    @Test func theLibraryIsCleared() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        f.store.archiveTab(a.id, reason: .manual)
        f.store.archiveTab(b.id, reason: .manual)
        f.store.removeFromArchive(a.id)
        #expect(f.store.archive.map(\.id) == [b.id])
        f.store.clearArchive()
        #expect(f.store.archive.isEmpty)
    }

    @Test func clearingTodayArchivesItsTabs() {
        let f = StoreFixture()
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        f.store.createTab(url: "https://a.test/")
        f.store.createTab(url: "https://b.test/")
        f.store.clearToday()
        #expect(f.today().isEmpty && f.pinned() == [pinned.id])
        #expect(f.store.archive.count == 2 && f.store.archive.allSatisfy { $0.reason == .clear })
        f.store.clearToday(UUID())
    }

    @Test func idleTodayTabsArchiveThemselves() {
        let f = StoreFixture()
        let idle = f.store.createTab(url: "https://idle.test/")
        let open = f.store.createTab(url: "https://open.test/")
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        f.store.selectTab(open.id)
        f.clock.advance(by: f.store.settings.autoArchive.seconds + 1)
        f.store.settings.autoArchiveEnabled = false
        f.store.runAutoArchive()
        #expect(f.store.item(idle.id) != nil, "off means off")
        f.store.settings.autoArchiveEnabled = true
        f.store.runAutoArchive()
        #expect(f.store.item(idle.id) == nil && f.store.archive.first?.reason == .auto)
        #expect(f.store.item(open.id) != nil, "the open tab stays")
        #expect(f.store.item(pinned.id) != nil, "pinned tabs never archive")
    }

    // MARK: Live folders

    static func pr(_ number: Int, owner: String = "acme", repo: String = "app", title: String? = nil) -> LivePullRequest {
        LivePullRequest(owner: owner, repo: repo, number: number, title: title ?? "PR \(number)", author: "octo")
    }

    @Test func aLiveFolderIsMadeOnceAtTheTopOfPinned() {
        let f = StoreFixture()
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        #expect(f.pinned() == [folder.id, pinned.id] && folder.title == "Pull Requests" && folder.isLiveFolder)
        #expect(f.store.createLiveFolder(.github, inSpace: f.space.id)?.id == folder.id)
        #expect(f.store.liveFolder(.github, inSpace: f.space.id)?.id == folder.id)
        #expect(f.store.liveFolders.map(\.id) == [folder.id])
        #expect(f.store.liveFolder(.github, inSpace: UUID()) == nil && f.store.createLiveFolder(.github, inSpace: UUID()) == nil)
        f.store.updateLiveFolder(folder.id) { $0.filter.hiddenRepositories = ["acme/hidden"] }
        f.store.updateLiveFolder(f.space.pinnedContainerID) { $0.hiddenItems = ["x"] }
        #expect(f.store.item(folder.id)?.liveFolder?.filter.hiddenRepositories == ["acme/hidden"])
    }

    @Test func aNestedLiveFolderIsFound() {
        let f = StoreFixture()
        let outer = f.store.createFolder(named: "Outer", in: f.space.pinnedContainerID)
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.moveItem(folder.id, to: outer.id, index: nil)
        #expect(f.store.liveFolder(.github, inSpace: f.space.id)?.id == folder.id)
    }

    @Test func refreshesFillTheFolderAndMarkWhatIsNew() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.updateLiveFolder(folder.id) { $0.filter.hiddenRepositories = ["acme/hidden"] }
        f.store.applyLiveResults([Self.pr(1), Self.pr(2), Self.pr(9, repo: "hidden")], to: folder.id, ssoOrganizations: [])
        var kids = f.store.children(of: folder.id)
        #expect(kids.map { $0.tab?.liveItemURL } == [Self.pr(1).url, Self.pr(2).url])
        #expect(kids.allSatisfy { !$0.isUnread }, "the first fill isn't news")
        #expect(kids[0].tab?.liveSubtitle == "octo" && f.store.item(folder.id)?.liveFolder?.lastFetch == f.clock.now)

        f.clock.advance(by: 60)
        f.store.applyLiveResults([Self.pr(3), Self.pr(1, title: "PR 1 renamed")], to: folder.id, ssoOrganizations: [])
        kids = f.store.children(of: folder.id)
        #expect(kids.map { $0.tab?.liveItemURL } == [Self.pr(3).url, Self.pr(1).url, Self.pr(2).url])
        #expect(kids[0].isUnread && kids[1].tab?.savedTitle == "PR 1 renamed")
        #expect(kids[2].tab?.liveGoneAt == f.clock.now, "one that left the results is marked")

        f.store.updateTab(kids[1].id, url: Self.pr(1).url + "/files", title: "Files · acme/app")
        #expect(f.store.item(kids[1].id)?.tab?.savedTitle == "PR 1 renamed", "a live tab keeps the pull request's title")
        #expect(!f.store.setPinnedURL(kids[1].id, to: "https://x.test/"))

        f.clock.advance(by: 30)
        f.store.expireLiveItems(olderThan: 60)
        #expect(f.store.item(kids[2].id) != nil, "inside its grace period")
        f.clock.advance(by: 60)
        f.store.selectTab(kids[2].id)
        f.store.expireLiveItems(olderThan: 60)
        #expect(f.store.item(kids[2].id) != nil, "one open in a window stays")
        f.store.selectTab(kids[0].id)
        f.store.expireLiveItems(olderThan: 60)
        #expect(f.store.item(kids[2].id) == nil)
        #expect(f.sound)
    }

    @Test func anSSOLapseOnlyHidesPullRequests() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.applyLiveResults([Self.pr(1, owner: "sso-org"), Self.pr(2)], to: folder.id, ssoOrganizations: [])
        f.store.applyLiveResults([], to: folder.id, ssoOrganizations: ["SSO-Org"])
        let kids = f.store.children(of: folder.id)
        #expect(kids[0].tab?.liveGoneAt == nil && kids[1].tab?.liveGoneAt != nil)
        #expect(f.store.item(folder.id)?.liveFolder?.ssoOrganizations == ["SSO-Org"])
    }

    @Test func aFailedRefreshIsRememberedAndTheNextFillIsQuiet() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.applyLiveFailure(.notSignedIn, to: folder.id)
        #expect(f.store.item(folder.id)?.liveFolder?.lastError == .notSignedIn)
        f.store.applyLiveResults([Self.pr(1)], to: folder.id, ssoOrganizations: [])
        #expect(f.store.children(of: folder.id).allSatisfy { !$0.isUnread })
        #expect(f.store.item(folder.id)?.liveFolder?.lastError == nil)
        f.store.applyLiveResults([], to: UUID(), ssoOrganizations: [])
    }

    @Test func anOpenTabOnAPullRequestMovesIn() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        let open = f.store.createTab(url: "https://github.com/ACME/App/pull/7")
        let unrelated = f.store.createTab(url: "https://example.test/")
        f.store.applyLiveResults([Self.pr(7)], to: folder.id, ssoOrganizations: [])
        #expect(f.store.item(open.id)?.parentID == folder.id && f.store.item(open.id)?.tab?.savedURL == Self.pr(7).url)
        #expect(f.today() == [unrelated.id])
        #expect(f.sound)
    }

    @Test func aTabTakenOutOfALiveFolderStaysOut() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.applyLiveResults([Self.pr(1), Self.pr(2)], to: folder.id, ssoOrganizations: [])
        let kids = f.store.children(of: folder.id).map(\.id)
        f.store.moveItem(kids[0], to: f.space.todayContainerID, index: 0)
        #expect(f.store.item(kids[0])?.tab?.liveItemURL == nil)
        #expect(f.store.item(folder.id)?.liveFolder?.hiddenItems == [Self.pr(1).url])
        f.store.applyLiveResults([Self.pr(1), Self.pr(2)], to: folder.id, ssoOrganizations: [])
        #expect(f.store.children(of: folder.id).count == 1, "the next refresh doesn't bring it back")

        // Nothing is dropped in, and the folder never unpacks into Today.
        let tab = f.store.createTab(url: "https://other.test/")
        f.store.moveItem(tab.id, to: folder.id, index: nil)
        f.store.moveItem(folder.id, to: f.space.todayContainerID, index: nil)
        #expect(f.store.item(tab.id)?.parentID == f.space.todayContainerID && f.store.item(folder.id)?.parentID == f.space.pinnedContainerID)

        // Closed out of the folder: hidden, and ⇧⌘T puts it back in.
        f.store.archiveTab(kids[1], reason: .manual)
        #expect(f.store.item(folder.id)?.liveFolder?.hiddenItems.contains(Self.pr(2).url) == true)
        f.store.restoreArchived(kids[1])
        #expect(f.store.item(kids[1])?.parentID == folder.id)
        #expect(f.store.item(folder.id)?.liveFolder?.hiddenItems.contains(Self.pr(2).url) == false)
        #expect(f.sound)
    }

    @Test func aLiveTabRestoredElsewhereIsAnOrdinaryTab() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.applyLiveResults([Self.pr(1)], to: folder.id, ssoOrganizations: [])
        let tab = f.store.children(of: folder.id)[0].id
        f.store.archiveTab(tab, reason: .manual)
        f.store.deleteFolder(folder.id)
        let restored = f.store.restoreArchived(tab)
        #expect(restored?.tab?.liveItemURL == nil && restored?.tab?.liveGoneAt == nil)
        #expect(f.pinned() == [tab], "it was pinned, in a folder that is gone")
    }

    @Test func deletingALiveFolderTakesItsItems() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        f.store.applyLiveResults([Self.pr(1), Self.pr(2)], to: folder.id, ssoOrganizations: [])
        let kids = f.store.children(of: folder.id).map(\.id)
        f.store.deleteFolder(folder.id)
        #expect(kids.allSatisfy { f.store.item($0) == nil } && f.store.archive.isEmpty)
        #expect(f.sound)
    }

    @Test func theHiddenListStaysShort() {
        let f = StoreFixture()
        let folder = f.store.createLiveFolder(.github, inSpace: f.space.id)!
        let prs = (1...201).map { Self.pr($0) }
        f.store.applyLiveResults(prs, to: folder.id, ssoOrganizations: [])
        for c in f.store.children(of: folder.id) { f.store.archiveTab(c.id, reason: .manual) }
        #expect(f.store.item(folder.id)?.liveFolder?.hiddenItems.count == 200)
    }

    // MARK: GitHub links

    @Test func pullRequestLinksAreRead() {
        let p = GitHubLink.pullPath("https://github.com/acme/app.js/pull/42/files")
        #expect(p?.owner == "acme" && p?.repo == "app.js" && p?.number == 42)
        #expect(GitHubLink.pullPath("/acme/app/pull/7")?.number == 7)
        #expect(GitHubLink.pullPath("https://github.com/acme/app/issues/7") == nil)
        #expect(GitHubLink.pullPath("https://github.com/acme/app/pull/99999999999999999999") == nil)
    }
}
