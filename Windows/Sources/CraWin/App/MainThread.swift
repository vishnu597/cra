import Foundation

/// A value moved across an isolation boundary that the compiler can't see is safe.
struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
}

/// Runs `body` on the main actor, here and now. Chromium (with its external message pump,
/// CraCEFWin.h) and WinUI both call back on the process's main thread, which is the main
/// actor's; this says so to the compiler and traps if it is ever not true.
@discardableResult
func onMain<T>(_ body: @MainActor () -> T) -> T {
    MainActor.assumeIsolated { UncheckedSendable(value: body()) }.value
}
