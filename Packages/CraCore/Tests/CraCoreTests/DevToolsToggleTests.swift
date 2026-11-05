import CraCore
import Testing

/// DevTools follow Cra's requests and CEF's callbacks, so a press made while they close is
/// remembered instead of closing them again; Console and Network switch panels and close only
/// their own (GitHub #88, #138). Moved from the Mac's policy tests.
struct DevToolsToggleTests {
    @Test func aPressWhileClosingIsRememberedNotSent() {
        var t = DevToolsToggle()
        var e = t.toggle()
        #expect(e == .show && t.state == .opening, "closed: a press opens")
        t.didOpen()
        e = t.toggle()
        #expect(e == .close && t.state == .closing(reopen: false), "open: a press closes")
        e = t.toggle()
        #expect(e == .none && t.state == .closing(reopen: true), "closing: a press is remembered, not sent")
        e = t.toggle()
        #expect(e == .none && t.state == .closing(reopen: false), "a third press takes it back")
        e = t.didClose()
        #expect(e == .none && t.state == .closed, "closed with nothing pending stays closed")
        _ = t.toggle()
        t.didOpen()
        _ = t.toggle()
        e = t.show()
        #expect(e == .none && t.state == .closing(reopen: true), "Inspect Element while closing waits for the close")
        e = t.didClose()
        #expect(e == .show && t.state == .opening, "and opens them once closed")
        t.didOpen()
        e = t.show()
        #expect(e == .show && t.state == .open, "Inspect Element on open DevTools moves them to the element")
    }

    @Test func devToolsOpenedOrClosedElsewhereFollowTheNextPress() {
        var external = DevToolsToggle()
        external.didOpen()
        let state = external.state
        let pressed = external.toggle()
        #expect(state == .open && pressed == .close, "DevTools opened from Chromium's menu close on the next press")
        var userClosed = DevToolsToggle()
        _ = userClosed.toggle()
        userClosed.didOpen()
        let closed = userClosed.didClose()
        let next = userClosed.toggle()
        #expect(closed == .none && next == .show, "closed from DevTools' own button: the next press opens")
    }

    @Test func consoleAndNetworkSwitchPanelsAndCloseOnlyTheirOwn() {
        var bar = DevToolsToggle()
        var r = bar.run(.console)
        #expect(r.effect == .show && r.frontend == "console", "Console on closed DevTools opens them on the Console")
        r = bar.run(.network)
        #expect(r.effect == .none && r.frontend == "network" && bar.state == .opening,
                "pressed while they open: they open on Network instead")
        bar.didOpen()
        bar.didShowPanel("console")
        r = bar.run(.network)
        #expect(r.effect == .frontend && r.frontend == "network" && bar.state == .open,
                "Network on the Console switches panel, DevTools stay open")
        r = bar.run(.network)
        #expect(r.effect == .close && r.frontend == nil && bar.state == .closing(reopen: false),
                "pressed again before the frontend reports the switch: Network shows, so it closes")
        r = bar.run(.network)
        #expect(r.effect == .none && r.frontend == "network" && bar.state == .closing(reopen: true),
                "pressed while closing: reopened on Network")
        r = bar.run(.console)
        #expect(r.effect == .none && r.frontend == nil && bar.state == .closing(reopen: false),
                "a second press takes the reopen back")
        r = bar.run(.console)
        #expect(r.effect == .none && r.frontend == "console", "a third asks again, on the Console")
        let reopened = bar.didClose()
        #expect(reopened == .show && bar.panel == nil, "once closed they reopen, the old panel forgotten")
        bar.didOpen()
        bar.didShowPanel("elements")
        r = bar.run(.console)
        #expect(r.effect == .frontend && r.frontend == "console", "Console on Elements switches")
        bar.didShowPanel("console")
        r = bar.run(.console)
        #expect(r.effect == .close && r.frontend == nil, "Console on the Console closes")
        let closed = bar.didClose()
        #expect(closed == .none && bar.state == .closed && bar.panel == nil, "and stays closed")
        bar.didShowPanel("network")
        #expect(bar.panel == nil, "a report from a closed frontend is dropped")
    }

    @Test func inspectAlwaysEndsOpenAndTheToggleKeepsThePanel() {
        var unknown = DevToolsToggle()
        unknown.didOpen()
        var r = unknown.run(.console)
        #expect(r.effect == .frontend && r.frontend == "console", "a frontend that never said its panel: switch, never close")
        var bar = DevToolsToggle()
        _ = bar.run(.console)
        bar.didOpen()
        r = bar.run(.inspect)
        #expect(r.effect == .show && r.frontend == "inspect" && bar.state == .open, "Inspect never closes: the picker on open DevTools")
        r = bar.run(.toggle)
        #expect(r.effect == .close && r.frontend == nil, "the toggle closes")
        var plain = DevToolsToggle()
        r = plain.run(.toggle)
        #expect(r.effect == .show && r.frontend == nil, "the toggle opens DevTools as they were")
    }
}
