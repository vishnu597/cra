import Foundation

/// The decisions pulled out of the window controllers: what an extension click does and the
/// feature flags (the toolbar's buttons and the DevTools toggle moved to CraCore). Table tests,
/// no AppKit views.
@main
enum PolicyTests {
    private static var checks = 0

    @MainActor
    static func main() {
        extensionLaunch()
        featureFlags()
        print("Policies: \(checks) checks passed")
    }

    private static func extensionLaunch() {
        typealias E = ExtensionLaunch.Extension
        let popup = E(id: "pop", popupPath: "popup.html", optionsPath: "options.html")
        let options = E(id: "opt", popupPath: nil, optionsPath: "settings.html")
        let bare = E(id: "bare")
        let off = E(id: "off", popupPath: "popup.html", enabled: false)
        let all = [popup, options, bare, off]
        expect(ExtensionLaunch.decide("pop", available: all, hasPage: true) == .runAction, "with a page, Chrome runs the action")
        expect(ExtensionLaunch.decide("off", available: all, hasPage: true) == .nothing,
               "a click never reaches an extension turned off in chrome://extensions")
        expect(ExtensionLaunch.decide("off", available: all, hasPage: false) == .nothing, "not even without a page")
        expect(ExtensionLaunch.fallback(off) == .nothing, "nor when Chrome's action failed")
        expect(ExtensionLaunch.decide("gone", available: all, hasPage: true) == .nothing, "an extension of another profile does nothing")
        expect(ExtensionLaunch.decide("pop", available: all, hasPage: false) == .popupWindow(url: "chrome-extension://pop/popup.html"),
               "no page: the popup page in its own window")
        expect(ExtensionLaunch.decide("opt", available: all, hasPage: false) == .openTab(url: "chrome-extension://opt/settings.html"),
               "no popup: the options page in a tab")
        expect(ExtensionLaunch.decide("bare", available: all, hasPage: false) == .openTab(url: "chrome://extensions/?id=bare"),
               "neither: Chrome's details page for it")
    }

    private static func featureFlags() {
        expect(FeatureFlags(parsing: "").backdrop == .layer, "the calibrated backdrop layer is the default")
        expect(FeatureFlags(parsing: "backdrop=material").backdrop == .material, "CRA_FLAGS picks the material path")
        expect(FeatureFlags(parsing: "x=1&backdrop=material&y").backdrop == .material, "other keys around it are ignored")
        expect(FeatureFlags(parsing: "backdrop=glass").backdrop == .layer && FeatureFlags(parsing: "backdrop").backdrop == .layer,
               "an unknown value or a bare key keeps the default")
        expect(FeatureFlags(parsing: "backdrop=material").summary == "backdrop=material", "the log line names the path")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
        checks += 1
    }
}
