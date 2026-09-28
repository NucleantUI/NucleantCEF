// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantUI`) or against GitHub.
///
/// Decided the same way in every Nucleant package, so one setting covers the
/// whole chain: `NUCLEANT_LOCAL_DEV=1|0` in the environment wins; otherwise
/// local when the sibling checkout exists next to this package — true in a
/// development tree, false for a clone SwiftPM made under `.build/checkouts`.
let devMode: Bool = {
    if let flag = ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] {
        return ["1", "true", "yes"].contains(flag.lowercased())
    }
    let siblings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: siblings.appendingPathComponent("NucleantUI").path)
}()

func getDependencies() -> [Package.Dependency] {
    devMode
        ? [.package(path: "../NucleantUI")]
        : [.package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master")]
}

/// The CEF binary distribution, unpacked by `scripts/fetch_cef.py` — macOS
/// x86-64 only for now. Its `include/` is what every C++ target compiles
/// against (CEF's headers include each other as "include/…", so the search
/// path is the distribution's root), and its `libcef_dll/` is the C++ wrapper
/// compiled below as a target of its own.
let cefRoot = "Dependencies/cef_macosx64"

let package = Package(
    name: "NucleantCEF",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NucleantCEF", targets: ["NucleantCEF"]),
        .executable(name: "NucleantCEFHelper", targets: ["NucleantCEFHelper"]),
        .executable(name: "NucleantCEFDemo", targets: ["NucleantCEFDemo"]),
    ],
    dependencies: getDependencies(),
    targets: [
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
    ],
    cxxLanguageStandard: .cxx20
)
