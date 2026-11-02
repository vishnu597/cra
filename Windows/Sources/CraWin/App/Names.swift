import Foundation

// Names the Windows SDK and WinRT projections also declare, pinned to the ones the app means
// in every file (a module's own declarations win over imported ones).

/// Foundation's, not WinSDK's UUID (the Windows SDK's GUID).
typealias UUID = Foundation.UUID
