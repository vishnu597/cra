import Foundation

/// Where the tabs a Peek or a page's links make go (BrowserManager.openLinkTab and the Peek's
/// Add To Split on the Mac).
extension SidebarStore {
    /// A link a page opens in a new tab (target=_blank, Ctrl-click, a link leaving a Peek, #202):
    /// in the space of the tab it came from, right below that tab when it is a Today tab (Arc),
    /// otherwise where new tabs go. A background tab is left unread.
    @discardableResult
    public func openLinkTab(_ url: String, from source: UUID?, inBackground background: Bool, window: UUID? = nil) -> SidebarItem {
        let space = source.flatMap { spaceID(ofItem: $0) }
        var parent: UUID?, index: Int?
        if let source, let item = item(source), let p = item.parentID, case .today = rootContainer(of: source) {
            parent = p
            index = (self.item(p)?.children.firstIndex(of: source) ?? -1) + 1
        }
        return createTab(url: url, in: space, select: !background, parent: parent, index: index, window: window)
    }

    /// A split under `source` can take another pane (Arc stops at four).
    public func canAddPane(to source: UUID) -> Bool {
        paneTabIDs(for: source).count < SplitPaneLayout.Constants.maximumPanes
    }

    /// Add To Split from a Peek (Arc's openInSplit), first half: the peeked page as a new tab in
    /// `source`'s space, and the tab it joins. Arc leaves a pinned tab or favorite where it is:
    /// outside a split its partner is a new Today tab at the top with a copy of its page. Nil when
    /// `source`'s split is full ("Cannot Add New Pane"). The app moves the live page into `tab`,
    /// then calls `joinSplit`.
    public func peekSplitTabs(url: String, title: String, beside source: UUID, window: UUID? = nil) -> (tab: UUID, partner: UUID)? {
        guard item(source)?.isTab == true, canAddPane(to: source) else { return nil }
        let sid = spaceID(ofItem: source) ?? focusedSpaceID(window: window)
        var partner = source
        if isPinned(source), splitContaining(source) == nil, let page = item(source)?.tab {
            partner = createTab(url: page.url, title: page.savedTitle, in: sid, select: false, window: window).id
        }
        let tab = createTab(url: url, title: title, in: sid, select: false, window: window)
        return (tab.id, partner)
    }

    /// Second half: `tab` joins `partner`'s split (or a new one at `partner`'s place) and its
    /// pane is selected.
    public func joinSplit(_ tab: UUID, with partner: UUID, window: UUID? = nil) {
        let split: SidebarItem?
        if let existing = splitContaining(partner) {
            addToSplit(existing.id, tabID: tab, at: nil)
            split = item(existing.id)
        } else {
            split = createSplit(with: [partner, tab], at: partner)
        }
        selectTab(split.flatMap { paneID(for: tab, in: $0) } ?? tab, window: window)
    }
}
