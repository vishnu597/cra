import Foundation
import WinAppSDK
import WinSDK

/// The app's message loop: swift-winui's default loop, except that Chromium's windows get their
/// messages straight away. WinUI's `ContentPreTranslateMessage` takes the real mouse and
/// keyboard input of every window under a WinUI window for XAML's input site, so a CEF page
/// there would show but never get a click or a key (posted messages still got through, which
/// is how this was found).
enum MessageLoop {
    /// Runs on the UI thread when the loop gets WM_QUIT, while XAML is still up.
    nonisolated(unsafe) static var willQuit: (() -> Void)?

    private typealias PreTranslate = @convention(c) (UnsafePointer<MSG>?) -> Bool
    private static let contentPreTranslateMessage: PreTranslate? = {
        guard let dll = LoadLibraryA("Microsoft.UI.Windowing.Core.dll"),
              let proc = GetProcAddress(dll, "ContentPreTranslateMessage") else { return nil }
        return unsafeBitCast(proc, to: PreTranslate.self)
    }()

    static func run(_ queue: WinAppSDK.DispatcherQueue) throws -> Int32 {
        var msg = MSG()
        while true {
            while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                if msg.message == UINT(WM_QUIT) {
                    willQuit?()
                    return Int32(msg.wParam)
                }
                if isChromium(msg.hwnd) || !(contentPreTranslateMessage?(&msg) ?? false) {
                    TranslateMessage(&msg)
                    DispatchMessageW(&msg)
                }
            }
            // Foundation's run loop and the main dispatch queue, as swift-winui's loop runs them.
            var next: Date?
            repeat {
                next = Foundation.RunLoop.main.limitDate(forMode: .default)
            } while (next?.timeIntervalSinceNow ?? -1) <= 0
            let wait = next.map { DWORD(max(0, min($0.timeIntervalSinceNow * 1000, Double(UInt32.max - 1)))) } ?? INFINITE
            _ = MsgWaitForMultipleObjects(0, nil, false, wait, DWORD(QS_ALLINPUT))
        }
    }

    /// Ends the process once everything is saved and Chromium has shut down. What is left is
    /// swift-winui's teardown after its loop returns, which releases the XAML manager and the
    /// dispatcher queue without shutting them down, and every close then ended in a WinRT
    /// fail-fast (0xE0464645 in WindowsFoundation.dll, seen on a PC). Nothing is lost by
    /// skipping it.
    static func finish() -> Never {
        TerminateProcess(GetCurrentProcess(), 0)
        fatalError("TerminateProcess returned")
    }

    /// Chromium's windows all have classes named Chrome_… (Chrome_WidgetWin_1,
    /// Chrome_RenderWidgetHostHWND, and the popups of <select> and the like).
    private static func isChromium(_ hwnd: HWND?) -> Bool {
        guard let hwnd else { return false }
        var name = [WCHAR](repeating: 0, count: 16)
        let count = GetClassNameW(hwnd, &name, Int32(name.count))
        return count >= 7 && Array(name[0..<7]) == Array("Chrome_".utf16)
    }
}
