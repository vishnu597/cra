import CraCore
import Foundation
import Testing

/// Moving things around the sidebar: folders, favorites, split views and the moves between them.
@MainActor
struct SidebarStoreTreeTests {
    // MARK: Moves

    @Test func movingIntoPinnedMakesTheCurrentPageHome() {
        let f = StoreFixture()
        let tab = f.store.createTab(url: "https://a.test/")
        f.store.updateTab(tab.id, url: "https://a.test/deep")
        f.store.pinTab(tab.id)
        #expect(f.pinned() == [tab.id] && f.store.item(tab.id)?.tab?.savedURL == "https://a.test/deep")
        f.store.unpinTab(tab.id)
        #expect(f.today() == [tab.id])
        f.store.togglePinned(tab.id)
        #expect(f.store.isPinned(tab.id))
        f.store.togglePinned(tab.id)
        #expect(!f.store.isPinned(tab.id))
        #expect(f.sound)
    }

    @Test func movingWithinAListCountsTheGapItLeaves() {
        let f = StoreFixture()
        f.store.settings.newTabsAtTop = false
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        let c = f.store.createTab(url: "https://c.test/")
        f.store.moveItem(a.id, to: f.space.todayContainerID, index: 2)
        #expect(f.today() == [b.id, a.id, c.id])
        f.store.moveItem(c.id, to: f.space.todayContainerID, index: 0)
        #expect(f.today() == [c.id, b.id, a.id])
        f.store.moveItems([a.id, b.id], to: f.space.pinnedContainerID, index: 0)
        #expect(f.pinned() == [a.id, b.id])
        f.store.moveItems([c.id], to: f.space.pinnedContainerID, index: nil)
        #expect(f.pinned() == [a.id, b.id, c.id])
    }

    @Test func impossibleMovesAreRefused() {
        let f = StoreFixture()
        let folder = f.store.createFolder(named: "Outer", in: f.space.pinnedContainerID)
        let inner = f.store.createFolder(named: "Inner", in: folder.id)
        f.store.moveItem(folder.id, to: inner.id, index: nil)
        f.store.moveItem(folder.id, to: folder.id, index: nil)
        f.store.moveItem(folder.id, to: UUID(), index: nil)
        f.store.moveItem(UUID(), to: folder.id, index: nil)
        #expect(f.store.item(folder.id)?.parentID == f.space.pinnedContainerID && f.store.item(inner.id)?.parentID == folder.id)
        #expect(f.sound)
    }

    @Test func aFolderDroppedInTodayUnpacks() {
        let f = StoreFixture()
        let folder = f.store.createFolder(named: "Box", in: f.space.pinnedContainerID)
        let a = f.store.createTab(url: "https://a.test/", parent: folder.id)
        let b = f.store.createTab(url: "https://b.test/", parent: folder.id)
        let old = f.store.createTab(url: "https://old.test/")
        f.store.moveItem(folder.id, to: f.space.todayContainerID, index: 0)
        #expect(f.store.item(folder.id) == nil)
        #expect(Set(f.today().prefix(2)) == [a.id, b.id] && f.today().last == old.id)
        #expect(f.sound)
    }

    @Test func tabsMoveBetweenSpacesKeepingTheirKind() {
        let f = StoreFixture()
        let personal = f.space
        let fav = f.store.createTab(url: "https://fav.test/")
        f.store.addToFavorites(fav.id)
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        let today = f.store.createTab(url: "https://today.test/")
        let work = f.store.createSpace(title: "Work", emoji: "💼", focus: false)
        f.store.moveTab(fav.id, toSpace: work.id)
        f.store.moveTab(pinned.id, toSpace: work.id)
        f.store.moveTab(today.id, toSpace: work.id)
        f.store.moveTab(today.id, toSpace: UUID())
        #expect(f.favorites(work) == [fav.id] && f.pinned(work) == [pinned.id] && f.today(work) == [today.id])
        #expect(f.favorites(personal).isEmpty)
        #expect(f.store.spaceID(ofItem: today.id) == work.id)
        #expect(f.store.integrityProblems().allSatisfy { $0.contains("lives elsewhere") },
                "a window still selecting a moved tab is the window controller's to fix")
    }

    // MARK: Favorites

    @Test func favoritesTakeTheSharedTileColor() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        f.store.addToFavorites(a.id)
        f.store.setTileColor("#00FF00", for: [a.id])
        f.store.addToFavorites(b.id)
        #expect(f.favorites() == [a.id, b.id] && f.store.isFavorite(b.id) && f.store.isPinned(b.id))
        #expect(f.store.item(b.id)?.tab?.tileColor == "#00FF00")
        #expect(f.store.favoriteTabs(in: f.space).map(\.id) == [a.id, b.id])
        f.store.removeFromFavorites(b.id)
        #expect(f.pinned() == [b.id] && !f.store.isFavorite(b.id))
        f.store.addToFavorites(f.space.todayContainerID)
        f.store.removeFromFavorites(UUID())
        f.store.pinTab(UUID())
        f.store.unpinTab(UUID())
        #expect(f.sound)
    }

    // MARK: Folders

    @Test func foldersAreMadeOpenAndUncollapseTheirList() {
        let f = StoreFixture()
        f.store.togglePinnedCollapsed(f.space.id)
        #expect(f.store.isPinnedCollapsed(f.space.id))
        let folder = f.store.createFolder(named: "Reading", in: f.space.pinnedContainerID)
        #expect(f.store.isExpanded(folder.id) && !f.store.isPinnedCollapsed(f.space.id))
        f.store.setExpanded(folder.id, false)
        #expect(!f.store.isExpanded(folder.id))
        f.store.setFolderIcon(.black, for: folder.id)
        f.store.setFolderIcon(.white, for: f.space.pinnedContainerID)
        #expect(f.store.item(folder.id)?.folderIcon == .black)
        let inside = f.store.createTab(url: "https://in.test/", parent: folder.id)
        #expect(!f.store.listedTabIDs(in: f.space.id).contains(inside.id), "a closed folder's tabs aren't listed")
        f.store.setExpanded(folder.id, true)
        #expect(f.store.listedTabIDs(in: f.space.id).contains(inside.id))
        f.store.togglePinnedCollapsed(f.space.id)
        f.store.togglePinnedCollapsed(f.space.id)
        #expect(!f.store.isPinnedCollapsed(f.space.id))
    }

    /// Upstream 154d357 (PinnedPeek): the open tab's row stays in sight after a Today tab is
    /// picked, as in Arc; it used to vanish.
    @Test func aCollapsedPinnedListShowsOnlyTheOpenTab() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/", pinned: true)
        let b = f.store.createTab(url: "https://b.test/", pinned: true)
        #expect(f.store.listedPinnedItems(in: f.space).map(\.id) == [a.id, b.id])
        f.store.togglePinnedCollapsed(f.space.id)
        #expect(f.store.listedPinnedItems(in: f.space).map(\.id) == [b.id])
        f.store.createTab(url: "https://today.test/")
        #expect(f.store.listedPinnedItems(in: f.space).map(\.id) == [b.id])
    }

    @Test func droppingATabOnAnotherMakesAFolder() {
        let f = StoreFixture()
        let p = f.store.createTab(url: "https://p.test/", pinned: true)
        let q = f.store.createTab(url: "https://q.test/", pinned: true)
        let t = f.store.createTab(url: "https://t.test/")
        let pinnedFolder = f.store.createFolder(combining: q.id, with: t.id, named: "Pair")
        #expect(f.pinned() == [p.id, pinnedFolder!.id], "a pinned target's folder takes its place")
        #expect(pinnedFolder?.children == [q.id, t.id])
        let u = f.store.createTab(url: "https://u.test/")
        let v = f.store.createTab(url: "https://v.test/")
        let todayFolder = f.store.createFolder(combining: u.id, with: [v.id, u.id])
        #expect(f.pinned().last == todayFolder?.id && todayFolder?.title == "New Folder", "a Today target's folder goes to pinned")
        #expect(f.store.createFolder(combining: u.id, with: [u.id]) == nil)
        #expect(f.store.createFolder(combining: todayFolder!.id, with: [p.id]) == nil)
        let w = f.store.createTab(url: "https://w.test/")
        let top = f.store.createFolder(with: [w.id], named: "Top")
        #expect(f.pinned().first == top.id && top.children == [w.id])
        #expect(f.sound)
    }

    @Test func deletingAFolderArchivesWhatWasInIt() {
        let f = StoreFixture()
        let folder = f.store.createFolder(named: "Outer", in: f.space.pinnedContainerID)
        let inner = f.store.createFolder(named: "Inner", in: folder.id)
        let a = f.store.createTab(url: "https://a.test/", parent: folder.id)
        let b = f.store.createTab(url: "https://b.test/", parent: inner.id)
        let c = f.store.createTab(url: "https://c.test/", parent: folder.id)
        let d = f.store.createTab(url: "https://d.test/", parent: folder.id)
        f.store.createSplit(with: [c.id, d.id])
        f.store.deleteFolder(folder.id)
        #expect(f.store.item(folder.id) == nil && f.store.item(inner.id) == nil && f.pinned().isEmpty)
        #expect(Set(f.store.archive.map(\.id)).isSuperset(of: [a.id, b.id]))
        f.store.deleteFolder(f.space.pinnedContainerID)
        #expect(f.store.item(f.space.pinnedContainerID) != nil)
        #expect(f.sound)
    }

    // MARK: Split view

    @Test func todayTabsSplitInPlace() {
        let f = StoreFixture()
        f.store.settings.newTabsAtTop = false
        let top = f.store.createTab(url: "https://top.test/")
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        f.clock.advance(by: 3)
        let split = f.store.createSplit(with: [a.id, b.id])!
        #expect(f.today() == [top.id, split.id] && split.children == [a.id, b.id])
        #expect(split.split?.focusTabID == a.id && split.split?.timeLastActiveAt == f.clock.now)
        #expect(f.store.splitContaining(b.id)?.id == split.id && f.store.splitContaining(top.id) == nil)
        #expect(f.store.paneTabIDs(for: b.id) == [a.id, b.id] && f.store.paneTabIDs(for: top.id) == [top.id])
        f.store.selectTab(b.id)
        #expect(f.store.item(split.id)?.split?.focusTabID == b.id)
        #expect(f.store.visiblePaneTabIDs(in: f.space.id) == [a.id, b.id])
        #expect(f.store.tabs(under: f.space.todayContainerID).map(\.id) == [top.id, a.id, b.id])
        f.store.selectTab(nil)
        #expect(f.store.visiblePaneTabIDs(in: f.space.id).isEmpty)
        #expect(f.store.createSplit(with: [f.space.todayContainerID]) == nil)
        #expect(f.sound)
    }

    @Test func aPinnedTabSplitsAsACopy() {
        let f = StoreFixture()
        let pinned = f.store.createTab(url: "https://pinned.test/", title: "Pinned", pinned: true)
        let other = f.store.createTab(url: "https://other.test/")
        let split = f.store.createSplit(with: [pinned.id, other.id])!
        #expect(f.pinned() == [pinned.id], "the pinned tab stays")
        #expect(f.today().first == split.id && split.children.count == 2 && !split.children.contains(pinned.id))
        let copy = f.store.paneID(for: pinned.id, in: split)!
        #expect(f.store.item(copy)?.tab?.url == "https://pinned.test/" && split.split?.focusTabID == copy)
        #expect(f.store.paneID(for: other.id, in: split) == other.id)
        // Adding to a split one of whose tabs is the first: the others join it.
        let third = f.store.createTab(url: "https://third.test/")
        let same = f.store.createSplit(with: [other.id, third.id])
        #expect(same?.id == split.id && same?.children.last == third.id)
        #expect(f.sound)
    }

    @Test func panesAreAddedMovedAndSeparated() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let empty = f.store.addEmptyPane(nextTo: a.id)!
        let split = f.store.splitContaining(a.id)!
        #expect(split.children == [a.id, empty.id] && f.store.selectedTabID == empty.id && empty.isEmptyTab)
        let before = f.store.addEmptyPane(nextTo: a.id, after: false, url: "https://before.test/")!
        #expect(f.store.item(split.id)?.children == [before.id, a.id, empty.id])
        #expect(f.store.addEmptyPane(nextTo: split.id) == nil)

        let loose = f.store.createTab(url: "https://loose.test/")
        f.store.addToSplit(split.id, tabID: loose.id, at: 1)
        #expect(f.store.item(split.id)?.children == [before.id, loose.id, a.id, empty.id])
        f.store.addToSplit(split.id, tabID: loose.id, at: 4)
        #expect(f.store.item(split.id)?.children == [before.id, a.id, empty.id, loose.id], "a pane already there moves")
        f.store.moveWithinSplit(split.id, tabID: loose.id, to: 0)
        #expect(f.store.item(split.id)?.children.first == loose.id)
        let pinned = f.store.createTab(url: "https://pinned.test/", pinned: true)
        f.store.addToSplit(split.id, tabID: pinned.id, at: nil)
        #expect(f.pinned() == [pinned.id] && f.store.paneID(for: pinned.id, in: f.store.item(split.id)!) != nil)
        let dropped = f.store.createTab(url: "https://dropped.test/")
        f.store.moveItem(dropped.id, to: split.id, index: 0)
        #expect(f.store.item(split.id)?.children.first == dropped.id, "dropping a tab on a split adds a pane")

        f.store.setSplitWidthFactors(split.id, [a.id: 0.7])
        #expect(f.store.item(split.id)?.split?.widthFactors == [a.id: 0.7])
        f.store.flipSplitOrientation(split.id)
        #expect(f.store.item(split.id)?.split?.orientation == .vertical)
        f.store.flipSplitOrientation(split.id)
        #expect(f.store.item(split.id)?.split?.orientation == .horizontal)

        f.store.separateFromSplit(a.id)
        let splitIndex = f.today().firstIndex(of: split.id)!
        #expect(f.today()[splitIndex + 1] == a.id && f.store.splitContaining(a.id) == nil)
        f.store.separateAll(split.id)
        #expect(f.store.item(split.id) == nil && f.store.splitContaining(empty.id) == nil)
        #expect(f.sound)
    }

    @Test func closingAPaneKeepsTheSplitOnScreen() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        let c = f.store.createTab(url: "https://c.test/")
        let split = f.store.createSplit(with: [a.id, b.id, c.id])!
        f.store.selectTab(b.id)
        f.store.archiveTab(b.id, reason: .manual)
        #expect(f.store.selectedTabID == a.id && f.store.item(split.id)?.children == [a.id, c.id])
        f.store.archiveTab(a.id, reason: .manual)
        #expect(f.store.item(split.id) == nil, "a split with one pane left dissolves")
        #expect(f.store.selectedTabID == c.id && f.today() == [c.id])
        #expect(f.sound)
    }

    @Test func aPaneDraggedOutTakesItsSplitDownToOne() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        let split = f.store.createSplit(with: [a.id, b.id])!
        f.store.selectTab(b.id)
        f.store.moveItem(b.id, to: f.space.pinnedContainerID, index: nil)
        #expect(f.store.item(split.id) == nil && f.today() == [a.id] && f.pinned() == [b.id])
        #expect(f.sound)
    }

    @Test func aSplitPinsAndFavoritesAsOne() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.test/")
        let b = f.store.createTab(url: "https://b.test/")
        let split = f.store.createSplit(with: [a.id, b.id])!
        f.store.updateTab(b.id, url: "https://b.test/deep")
        f.store.togglePinned(b.id)
        #expect(f.pinned() == [split.id] && f.store.item(b.id)?.tab?.savedURL == "https://b.test/deep")
        f.store.addToFavorites(a.id)
        #expect(f.favorites() == [split.id])
        f.store.removeFromFavorites(a.id)
        #expect(f.pinned() == [split.id])
        #expect(f.sound)
    }
}
