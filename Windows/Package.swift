// swift-tools-version:5.10
import PackageDescription

// The Windows shell of Cra: a WinUI 3 window (Swift/WinRT projections from The Browser
// Company) around Chromium through CEF. Shares the models in Packages/CraCore with the
// macOS app.
//
// Windows/scripts/fetch-deps.ps1 puts the dependencies in Windows/vendor:
//   vendor/cef        CEF's Windows binary distribution, with libcef_dll_wrapper built
//   vendor/winrt/*    swift-cwinrt, swift-uwp, swift-windowsfoundation,
//                     swift-windowsappsdk and swift-winui at pinned commits (their
//                     manifests refer to each other by relative path, so they sit side by side)
let root = Context.packageDirectory
let cefRoot = "\(root)/vendor/cef"
let winrt = "\(root)/vendor/winrt"

// The defines and runtime CEF builds its wrapper with (cmake/cef_variables.cmake), with
// the runtime switched to /MD because Swift on Windows links the DLL runtime.
let cefCXXFlags: [String] = [
    "-I", cefRoot,
    "-DWIN32", "-D_WINDOWS", "-DUNICODE", "-D_UNICODE", "-DNOMINMAX", "-DWIN32_LEAN_AND_MEAN",
    "-D_HAS_EXCEPTIONS=0",
]
let cefLinkerFlags: [String] = [
    "-L\(cefRoot)/build/libcef_dll_wrapper/Release",
    "-L\(cefRoot)/Release",
]

let package = Package(
    name: "CraWindows",
    products: [
        .executable(name: "Cra", targets: ["CraWin"]),
        .executable(name: "CraHelper", targets: ["CraHelperWin"]),
    ],
    dependencies: [
        .package(path: "../Packages/CraCore"),
        .package(path: "vendor/winrt/swift-winui"),
        .package(path: "vendor/winrt/swift-windowsappsdk"),
        .package(path: "vendor/winrt/swift-windowsfoundation"),
        .package(path: "vendor/winrt/swift-uwp"),
    ],
    targets: [
        // C++ bridge to CEF with a plain C surface (include/CraCEFWin.h), the Windows
        // counterpart of Sources/CraCEF, and the few Win32 helpers the shell needs (images
        // from WIC and Explorer, hiding Chrome's download animation, the clipboard, Share, the
        // Peek's veil and buttons).
        .target(
            name: "CraCEFWin",
            path: "Sources/CraCEFWin",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(cefCXXFlags)],
            linkerSettings: [
                .unsafeFlags(cefLinkerFlags),
                .linkedLibrary("libcef_dll_wrapper"),
                .linkedLibrary("libcef"),
                .linkedLibrary("user32"),
                .linkedLibrary("shell32"),  // SHGetKnownFolderPath (the Downloads folder)
                .linkedLibrary("ole32"),  // CoTaskMemFree, CoCreateInstance
                .linkedLibrary("gdi32"),  // GetDIBits (file thumbnails)
                .linkedLibrary("windowscodecs"),  // WIC (favicons, file thumbnails)
                .linkedLibrary("crypt32"),  // certificate stores (the site control center's certificate)
                .linkedLibrary("runtimeobject"),  // RoGetActivationFactory, HSTRINGs (the Share window)
                .linkedLibrary("gdiplus"),  // the Peek's round buttons (CraOverlay.cpp)
                .linkedLibrary("advapi32"),  // the registry (the round buttons' tips follow the apps' theme)
            ]
        ),
        // Every Chromium subprocess (renderer, GPU, utility) runs this executable.
        .executableTarget(
            name: "CraHelperWin",
            dependencies: ["CraCEFWin"],
            path: "Sources/CraHelperWin",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
            ]
        ),
        .executableTarget(
            name: "CraWin",
            dependencies: [
                "CraCEFWin",
                .product(name: "CraCore", package: "CraCore"),
                .product(name: "WinUI", package: "swift-winui"),
                .product(name: "WinAppSDK", package: "swift-windowsappsdk"),
                .product(name: "WindowsFoundation", package: "swift-windowsfoundation"),
                .product(name: "UWP", package: "swift-uwp"),
            ],
            path: "Sources/CraWin",
            linkerSettings: [
                .linkedLibrary("advapi32"),  // the registry (WinRegistry)
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                             .when(configuration: .release)),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
