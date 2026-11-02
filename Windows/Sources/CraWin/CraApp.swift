import CraCEFWin
import CraCore
import Foundation
import WinAppSDK
import WinSDK
import WinUI

/// The Windows app: starts Chromium, loads the shared SidebarStore from %LOCALAPPDATA%\Cra
/// (the Mac's data folder layout, read by the same CraCore code) and opens a BrowserWindow on it.
@main
public final class CraApp: SwiftApplication {
    // XAML objects can only be made once the app is launched, on its UI thread (making them in
    // init fails with RPC_E_WRONG_THREAD).
    @MainActor private var store: SidebarStore?
    @MainActor private var browser: BrowserWindow?
    @MainActor private var clock: WinScheduler?
    /// Auto-archive, as the Mac runs it (AppComposition): kept until the app quits.
    @MainActor private var periodic: [ScheduledWork] = []

    public required init() {
        super.init()
        unhandledException.addHandler { _, args in
            print("Unhandled exception: \(args?.message ?? "")")
        }
    }

    /// Chromium's windows bypass WinUI's input routing (MessageLoop).
    override public class var runLoop: SwiftApplication.RunLoop { MessageLoop.run }

    override public func onShutdown(exitCode: Int32) {}

    override public func onLaunched(_ args: WinUI.LaunchActivatedEventArgs) {
        guard startChromium() else {
            // Another Cra already runs on this profile and was handed this launch.
            // (Not `exit`: inside an Application that names its own exit() method.)
            if cra_cef_another_instance_was_notified() != 0 { ExitProcess(0) }
            print("Chromium did not start")
            return
        }
        guard let dispatcher = try? WinAppSDK.DispatcherQueue.getForCurrentThread() else {
            print("No dispatcher queue on the UI thread")
            return
        }
        // Saved and shut down while XAML is still up; then the process ends (MessageLoop.finish).
        MessageLoop.willQuit = { [weak self] in
            onMain { self?.store?.saveAll() }
            cra_cef_shutdown()
            MessageLoop.finish()
        }
        onMain {
            CoreLog.fault = { print("Cra fault: \($0)") }
            let clock = WinScheduler(queue: dispatcher)
            let store = SidebarStore(directory: WinPaths.supportDir, chromiumCache: WinPaths.chromiumCache, clock: clock)
            store.runAutoArchive()
            periodic = [clock.every(30 * 60) { store.runAutoArchive() }]
            self.clock = clock
            self.store = store
            do {
                browser = try BrowserWindow(store: store, dispatcher: dispatcher)
            } catch {
                print("The window could not be made: \(error)")
            }
        }
    }

    private func startChromium() -> Bool {
        let exe = CommandLine.arguments[0]
        let helper = URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent("CraHelper.exe").path
        CrashRecovery.prepare(cache: WinPaths.chromiumCache)
        let cache = WinPaths.chromiumCache.path
        let log = WinPaths.log.path
        return helper.withCString { h in
            cache.withCString { c in
                log.withCString { l in
                    "Cra/1.0".withCString { product in
                        var settings = CraCEFSettings()
                        settings.helper_path = h
                        settings.cache_root = c
                        settings.log_path = l
                        settings.user_agent_product = product
                        return cra_cef_initialize(&settings) != 0
                    }
                }
            }
        }
    }
}
