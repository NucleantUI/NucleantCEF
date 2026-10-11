//
//  CEFRuntime+Web.swift
//  NucleantCEF
//
//  The browser build's runtime: there is none to start. The browser the app
//  runs in is the engine every page is shown by (CEFBrowserBase+Web.swift),
//  already running and never shut down by the app. The API is the desktop's,
//  so code that configures or starts CEF builds for the browser too.
//

#if os(WASI)

/// The desktop's CEF settings. Not read in the browser build — there is no
/// framework, helper or cache of the app's own there.
@MainActor
public struct CEFConfiguration {
    public var frameworkDirectory: String
    public var helperPath: String
    public var rootCachePath: String
    public var cachePath: String?
    public var logSeverity: Int32 = 0
    public var remoteDebuggingPort: Int32 = 0

    public init() {
        frameworkDirectory = ""
        helperPath = ""
        rootCachePath = ""
    }
}

/// The browser's side of CEF's process: always there, from the first
/// browser on.
@MainActor
public enum CEFRuntime {

    /// Not read in the browser build.
    public static var configuration = CEFConfiguration()

    public enum State: Equatable {
        case notStarted
        case running
        /// Never in the browser build; kept for the desktop's switch.
        case failed(String)
        case shutDown
    }

    public private(set) static var state: State = .notStarted

    /// Running from the first call on, until `shutdown`.
    @discardableResult
    public static func start() -> Bool {
        if state == .notStarted { state = .running }
        return state == .running
    }

    /// The page goes when the browser tab does; this only marks the runtime
    /// as shut down.
    public static func shutdown(timeout: Double = 2) {
        guard state == .running else { return }
        state = .shutDown
    }
}
#endif
