// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantUI`) or against each
/// repo's releases on GitHub (`getDependencies()`).
///
/// GitHub unless `NUCLEANT_LOCAL_DEV=1` is in the environment: the sibling
/// checkouts are used only when that turns them on, never just because they
/// are there.
let devMode: Bool = ["1", "true", "yes"].contains(
    (ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] ?? "").lowercased()
)

/// WebAssembly (`WASM_BUILD=1`, the opt-in every Nucleant package reads): the
/// page the app runs in is a browser already, so `NucleantCEF` there is an
/// `<iframe>` laid over the view (`CEFBrowserBase+Web.swift`, on
/// NucleantApplication's `BrowserFrame`) — no CEF distribution, no C++
/// targets, no helper. Without it the manifest is the desktop's as it was.
let isWasm = ProcessInfo.processInfo.environment["WASM_BUILD"] == "1"

func getDependencies() -> [Package.Dependency] {
    // NucleantApplication for its `Platform_Wasm`, which NucleantUI already
    // depends on; the browser build names it to import `BrowserFrame`.
    let names = isWasm ? ["NucleantUI", "NucleantApplication"] : ["NucleantUI"]
    if devMode {
        return names.map { .package(path: "../\($0)") }
    }
    // Each by version, up to its next minor: its new 0.0.x releases are
    // picked up as they come; its 0.1.0 only once its line here is moved to it.
    var dependencies: [Package.Dependency] = [
        .package(url: "https://github.com/NucleantUI/NucleantUI.git", .upToNextMinor(from: "0.0.1")),
    ]
    if isWasm {
        dependencies.append(.package(url: "https://github.com/NucleantUI/NucleantApplication.git", .upToNextMinor(from: "0.0.1")))
    }
    return dependencies
}

/// The CEF binary distribution, unpacked by `scripts/fetch_cef.py` — macOS
/// x86-64 only for now. Its `include/` is what every C++ target compiles
/// against (CEF's headers include each other as "include/…", so the search
/// path is the distribution's root), and its `libcef_dll/` is the C++ wrapper
/// compiled below as a target of its own.
let cefRoot = "Dependencies/cef_macosx64"

let desktopProducts: [Product] = [
    .library(name: "NucleantCEF", targets: ["NucleantCEF"]),
    .executable(name: "NucleantCEFHelper", targets: ["NucleantCEFHelper"]),
    .executable(name: "NucleantCEFDemo", targets: ["NucleantCEFDemo"]),
]

/// The browser build: the Swift API alone, over an iframe.
let webProducts: [Product] = [
    .library(name: "NucleantCEF", targets: ["NucleantCEF"]),
]

let webTargets: [Target] = [
    .target(
        name: "NucleantCEF",
        dependencies: [
            .product(name: "NucleantUI", package: "NucleantUI"),
            .product(name: "Platform_Wasm", package: "NucleantApplication", condition: .when(platforms: [.wasi])),
        ]
    ),
]

let desktopTargets: [Target] = [
    // libcef_dll_wrapper: CEF's C++ API over the framework's C API. On
    // macOS it resolves every framework function at `cef_load_library`
    // time (libcef_dll_dylib.cc), so nothing links against the framework
    // itself. The sandbox context needs cef_sandbox.a, which this package
    // does not use (`no_sandbox`).
    .target(
        name: "CEFWrapper",
        path: "\(cefRoot)/libcef_dll",
        exclude: [
            "CMakeLists.txt",
            "wrapper/cef_scoped_sandbox_context_mac.mm",
        ],
        // Nothing is public: CNucleantCEF compiles against CEF's own
        // include/ tree. SwiftPM still wants a directory inside the
        // target, and base/ holds sources only.
        publicHeadersPath: "base",
        cxxSettings: [
            .headerSearchPath(".."),
            .define("WRAPPING_CEF_SHARED"),
        ],
        linkerSettings: [
            .linkedFramework("Cocoa"),
        ]
    ),
    // The C surface Swift calls (ncef.h).
    .target(
        name: "CNucleantCEF",
        dependencies: ["CEFWrapper"],
        cxxSettings: [
            .headerSearchPath("../../\(cefRoot)"),
        ],
        linkerSettings: [
            .linkedFramework("Cocoa"),
            .linkedFramework("IOSurface"),
        ]
    ),
    // The sub-process executable (`browser_subprocess_path`).
    .executableTarget(
        name: "NucleantCEFHelper",
        dependencies: ["CEFWrapper"],
        cxxSettings: [
            .headerSearchPath("../../\(cefRoot)"),
        ]
    ),
    .target(
        name: "NucleantCEF",
        dependencies: [
            "CNucleantCEF",
            .product(name: "NucleantUI", package: "NucleantUI"),
        ]
    ),
    .executableTarget(
        name: "NucleantCEFDemo",
        dependencies: [
            "NucleantCEF",
            .product(name: "NucleantUI", package: "NucleantUI"),
        ]
    ),
]

let package = Package(
    name: "NucleantCEF",
    platforms: [
        .macOS(.v14)
    ],
    products: isWasm ? webProducts : desktopProducts,
    dependencies: getDependencies(),
    targets: isWasm ? webTargets : desktopTargets,
    cxxLanguageStandard: .cxx20
)
