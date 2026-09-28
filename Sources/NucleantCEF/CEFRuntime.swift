//
//  CEFRuntime.swift
//  NucleantCEF
//
//  CEF's browser process, as a NucleantUI app hosts it: loaded and
//  initialized on the first browser, pumped from the main run loop, shut down
//  when the app terminates.
//

import AppKit
import CNucleantCEF

/// Where CEF's pieces are, and the process-wide settings it starts with.
///
/// Every path has a default that works for a `swift build` of this package —
/// and each can be overridden by the environment variable named beside it,
/// or by setting it here before the first browser is made.
@MainActor
public struct CEFConfiguration {
    /// "Chromium Embedded Framework.framework". `NUCLEANT_CEF_FRAMEWORK_DIR`;
    /// else the app bundle's `Contents/Frameworks`; else the distribution this
    /// package was built against (`scripts/fetch_cef.py`).
    public var frameworkDirectory: String

    /// The executable CEF runs for its sub-processes. `NUCLEANT_CEF_HELPER`;
    /// else `NucleantCEFHelper` beside the main executable, where a
    /// `swift build` of this package puts it.
    public var helperPath: String

    /// Installation-wide data; must be unique to the app — CEF refuses a
    /// second process on the same one (it hands the launch to the first).
    /// `NUCLEANT_CEF_ROOT_CACHE`; else `~/Library/Caches/<app>/NucleantCEF`.
    public var rootCachePath: String

    /// Profile data (cookies, local storage), a directory under
    /// `rootCachePath` — `nil`, the default, keeps the profile in memory.
    public var cachePath: String?

    /// `cef_log_severity_t` — 0 is CEF's default; 99 disables logging.
    public var logSeverity: Int32 = 0

    /// A port for Chrome DevTools to attach to (`chrome://inspect`); 0 is off.
    public var remoteDebuggingPort: Int32 = 0

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let executableDirectory = executable.deletingLastPathComponent()

        if let path = environment["NUCLEANT_CEF_FRAMEWORK_DIR"] {
            frameworkDirectory = path
        } else if let frameworks = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Chromium Embedded Framework.framework"),
            FileManager.default.fileExists(atPath: frameworks.path) {
            frameworkDirectory = frameworks.path
        } else {
            frameworkDirectory = CEFConfiguration.packageRoot
                .appendingPathComponent("Dependencies/cef_macosx64/Release/Chromium Embedded Framework.framework")
                .path
        }

        helperPath = environment["NUCLEANT_CEF_HELPER"]
            ?? executableDirectory.appendingPathComponent("NucleantCEFHelper").path

        let appName = Bundle.main.bundleIdentifier ?? executable.lastPathComponent
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        rootCachePath = environment["NUCLEANT_CEF_ROOT_CACHE"]
            ?? caches.appendingPathComponent(appName).appendingPathComponent("NucleantCEF").path
    }

    /// This package's checkout — `Sources/NucleantCEF/CEFRuntime.swift` is
    /// three levels down.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// CEF's browser process: started by the first browser, shut down with the
/// app.
@MainActor
public enum CEFRuntime {

    /// Read when CEF starts — set before the first browser is made.
    public static var configuration = CEFConfiguration()

    public enum State: Equatable {
        case notStarted
        case running
        /// CEF could not be loaded or initialized; no browser will ever render.
        case failed(String)
        case shutDown
    }

    public private(set) static var state: State = .notStarted

    /// Browsers made and not yet closed — shutdown waits for them.
    static var openBrowsers = 0

    /// Start CEF if it hasn't been, and say whether it is running.
    @discardableResult
    public static func start() -> Bool {
        switch state {
        case .running: return true
        case .failed, .shutDown: return false
        case .notStarted: break
        }
        let config = configuration
        guard FileManager.default.fileExists(atPath: config.frameworkDirectory) else {
            return fail("no CEF framework at \(config.frameworkDirectory) — run scripts/fetch_cef.py, "
                        + "or point NUCLEANT_CEF_FRAMEWORK_DIR at one")
        }
        guard FileManager.default.isExecutableFile(atPath: config.helperPath) else {
            return fail("no helper executable at \(config.helperPath) — build it with "
                        + "`swift build --product NucleantCEFHelper`, or point NUCLEANT_CEF_HELPER at one")
        }
        guard ncef_load_library(config.frameworkDirectory) == 1 else {
            return fail("loading \(config.frameworkDirectory) failed")
        }
        // Every sub-process CEF launches inherits this; the helper finds the
        // framework through it when CEF passes no --framework-dir-path.
        setenv("NUCLEANT_CEF_FRAMEWORK_DIR", config.frameworkDirectory, 1)

        let mainBundle = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundlePath
            : (Bundle.main.executableURL?.deletingLastPathComponent().path ?? Bundle.main.bundlePath)

        let initialized: Int32 = config.frameworkDirectory.withCString { framework in
            config.helperPath.withCString { helper in
                mainBundle.withCString { bundle in
                    config.rootCachePath.withCString { root in
                        withOptionalCString(config.cachePath) { cache in
                            var settings = ncef_settings()
                            settings.framework_dir = framework
                            settings.helper_path = helper
                            settings.main_bundle_path = bundle
                            settings.root_cache_path = root
                            settings.cache_path = cache
                            settings.log_severity = config.logSeverity
                            settings.remote_debugging_port = config.remoteDebuggingPort
                            settings.schedule_message_pump_work = { delay in
                                CEFMessagePump.schedule(after: delay)
                            }
                            return ncef_initialize(&settings)
                        }
                    }
                }
            }
        }
        guard initialized == 1 else {
            return fail("CefInitialize failed (exit code \(ncef_exit_code()))")
        }
        state = .running
        CEFMessagePump.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CEFRuntime.shutdown() }
        }
        return true
    }

    /// Close every browser, give them `timeout` seconds to finish closing, and
    /// shut CEF down. Called on app termination; safe to call again.
    public static func shutdown(timeout: TimeInterval = 2) {
        guard state == .running else { return }
        CEFBrowserBase.closeAll()
        let deadline = Date().addingTimeInterval(timeout)
        while openBrowsers > 0, Date() < deadline {
            ncef_do_message_loop_work()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        CEFMessagePump.stop()
        // Tasks CEF queued while the browsers closed.
        for _ in 0..<10 { ncef_do_message_loop_work() }
        state = .shutDown
        ncef_shutdown()
    }

    private static func fail(_ reason: String) -> Bool {
        print("NucleantCEF: \(reason)")
        state = .failed(reason)
        return false
    }
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

/// CEF's external message pump, on the main run loop.
///
/// CEF asks for work through `OnScheduleMessagePumpWork` (from any thread),
/// and that alone is not enough: the documented pattern pairs it with a timer
/// that runs the loop at a modest rate regardless, so nothing CEF schedules
/// without asking is left waiting. Both run in the run loop's common modes, so
/// a window being resized or a menu held open doesn't stall the page.
@MainActor
enum CEFMessagePump {
    /// The slowest the loop is ever left alone: 30 Hz.
    private static let maximumDelay: TimeInterval = 1.0 / 30.0

    private static var fallback: Timer?
    private static var scheduled: Timer?
    private static var isPerformingWork = false

    static func start() {
        let timer = Timer(timeInterval: maximumDelay, repeats: true) { _ in
            MainActor.assumeIsolated { CEFMessagePump.performWork() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallback = timer
    }

    static func stop() {
        fallback?.invalidate()
        fallback = nil
        scheduled?.invalidate()
        scheduled = nil
    }

    /// From `OnScheduleMessagePumpWork`, on whatever thread CEF is on.
    nonisolated static func schedule(after delayMilliseconds: Int64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CEFMessagePump.reschedule(after: delayMilliseconds) }
        }
    }

    private static func reschedule(after delayMilliseconds: Int64) {
        guard fallback != nil else { return }
        scheduled?.invalidate()
        let delay = min(max(0, TimeInterval(delayMilliseconds) / 1000), maximumDelay)
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                CEFMessagePump.scheduled = nil
                CEFMessagePump.performWork()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduled = timer
    }

    /// One turn of CEF's loop — never re-entered: CEF may ask for more work
    /// while it is doing some, and that is served by the next turn.
    private static func performWork() {
        guard !isPerformingWork, CEFRuntime.state == .running else { return }
        isPerformingWork = true
        ncef_do_message_loop_work()
        isPerformingWork = false
    }
}
