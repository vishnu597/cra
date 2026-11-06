import CraCore
import Foundation
import Testing

/// The tabs a Peek and a page's links make (SidebarStore.openLinkTab, peekSplitTabs, joinSplit),
/// shared by the Mac's BrowserManager and LittleWindowController and Windows' BrowserWindow and
/// LittleWindow.
@MainActor
struct PeekTabsTests {
    @Test func aLinkFromATodayTabOpensRightBelowIt() {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.example", select: true)
        let b = f.store.createTab(url: "https://b.example", select: true)
        let order = f.today()
        let link = f.store.openLinkTab("https://c.example", from: order.last!, inBackground: false)
        #expect(f.today() == order + [link.id], "below the last tab")
        let first = f.store.openLinkTab("https://d.example", from: order.first!, inBackground: false)
        #expect(f.today().firstIndex(of: first.id) == 1, "right below the first one")
        #expect(f.store.selectedTabID == first.id)
        _ = (a, b)
    }

    @Test func aLinkFromAPinnedTabGoesWhereNewTabsGo() {
        let f = StoreFixture()
        let pinned = f.store.createTab(url: "https://pinned.example", pinned: true, select: true)
        _ = f.store.createTab(url: "https://today.example", select: false)
        let link = f.store.openLinkTab("https://link.example", from: pinned.id, inBackground: true)
        #expect(f.pinned() == [pinned.id], "the pinned list keeps its tab alone")
        #expect(f.today().contains(link.id))
        #expect(f.store.item(link.id)?.isUnread == true, "a background tab is unread")
        #expect(f.store.selectedTabID == pinned.id, "and the page stays in front")
    }

    @Test func aLinkFromNowhereOpensInTheFocusedSpace() {
        let f = StoreFixture()
        let link = f.store.openLinkTab("https://link.example", from: nil, inBackground: false)
        #expect(f.today().contains(link.id))
        #expect(f.store.spaceID(ofItem: link.id) == f.space.id)
    }

    @Test func addToSplitJoinsATodayTabInItsPlace() throws {
        let f = StoreFixture()
        let source = f.store.createTab(url: "https://source.example", select: true)
        let made = try #require(f.store.peekSplitTabs(url: "https://peeked.example", title: "Peeked", beside: source.id))
        #expect(made.partner == source.id)
        f.store.joinSplit(made.tab, with: made.partner)
        let split = try #require(f.store.splitContaining(source.id))
        #expect(split.children == [source.id, made.tab])
        #expect(f.store.selectedTabID == made.tab)
        #expect(f.store.item(made.tab)?.tab?.url == "https://peeked.example")
        #expect(f.sound)
    }

    /// Arc leaves a pinned tab where it is: the split is a new one in Today with a copy of its page.
    @Test func addToSplitBesideAPinnedTabCopiesItsPage() throws {
        let f = StoreFixture()
        let pinned = f.store.createTab(url: "https://pinned.example", title: "Pinned", pinned: true, select: true)
        let made = try #require(f.store.peekSplitTabs(url: "https://peeked.example", title: "", beside: pinned.id))
        #expect(made.partner != pinned.id)
        #expect(f.store.item(made.partner)?.tab?.url == "https://pinned.example")
        f.store.joinSplit(made.tab, with: made.partner)
        #expect(f.pinned() == [pinned.id], "the pinned tab stays")
        let split = try #require(f.store.splitContaining(made.tab))
        #expect(split.children == [made.partner, made.tab])
        #expect(f.store.rootContainer(of: split.id) == .today(spaceID: f.space.id))
        #expect(f.sound)
    }

    @Test func addToSplitJoinsAnOpenSplitUntilItHoldsFour() throws {
        let f = StoreFixture()
        let a = f.store.createTab(url: "https://a.example", select: true)
        let b = f.store.createTab(url: "https://b.example", select: false)
        _ = f.store.createSplit(with: [a.id, b.id])
        let third = try #require(f.store.peekSplitTabs(url: "https://c.example", title: "", beside: a.id))
        #expect(third.partner == a.id)
        f.store.joinSplit(third.tab, with: third.partner)
        #expect(f.store.paneTabIDs(for: a.id) == [a.id, b.id, third.tab])
        #expect(f.store.canAddPane(to: a.id))
        let fourth = try #require(f.store.peekSplitTabs(url: "https://d.example", title: "", beside: b.id))
        f.store.joinSplit(fourth.tab, with: fourth.partner)
        #expect(f.store.paneTabIDs(for: a.id).count == 4)
        #expect(!f.store.canAddPane(to: a.id))
        let tabs = f.today().count
        #expect(f.store.peekSplitTabs(url: "https://e.example", title: "", beside: a.id) == nil, "Cannot Add New Pane")
        #expect(f.today().count == tabs, "and nothing was made")
        #expect(f.sound)
    }

    @Test func addToSplitNeedsATab() {
        let f = StoreFixture()
        #expect(f.store.peekSplitTabs(url: "https://a.example", title: "", beside: UUID()) == nil)
        #expect(f.store.peekSplitTabs(url: "https://a.example", title: "", beside: f.space.todayContainerID) == nil)
    }
}
