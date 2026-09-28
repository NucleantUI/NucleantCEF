//
//  CEFProtocols.swift
//  NucleantCEF
//
//  The protocols a browser model is built from — the same shape as
//  NucleantThorVG's `ThorPaint` / `ThorShape`: a protocol that names the
//  underlying handle (`base`), and extensions that turn CEF's API into
//  methods on whatever conforms. A model is then an `@Observable` class that
//  holds a `CEFBrowserBase` and keeps whichever of CEF's events it cares
//  about in properties of its own; `CEFView` takes any such model.
//

import NucleantUI
import CNucleantCEF

// MARK: - The browser

/// Something that owns one CEF browser — through `base`, which holds the
/// browser handle and everything the rendering side needs.
///
/// Everything CEF can be asked to do comes from this protocol's extension;
/// a conforming class only provides `base`.
@MainActor
public protocol CEFBrowser: AnyObject {
    var base: CEFBrowserBase { get }
}

public extension CEFBrowser {

    /// The browser has been created and not yet closed.
    var isBrowserOpen: Bool { base.isOpen }

    /// Load `url` — or, before the browser exists, make it the first page.
    func load(_ url: String) {
        base.load(url)
    }

    func goBack() {
        base.withHandle { ncef_browser_go_back($0) }
    }

    func goForward() {
        base.withHandle { ncef_browser_go_forward($0) }
    }

    func reload(ignoringCache: Bool = false) {
        base.withHandle { ncef_browser_reload($0, ignoringCache ? 1 : 0) }
    }

    func stopLoading() {
        base.withHandle { ncef_browser_stop_load($0) }
    }

    /// Run `script` in the main frame. Fire-and-forget: CEF has no result
    /// path for this; a page that needs to answer does it through a load or
    /// a console message.
    func evaluateJavaScript(_ script: String, sourceURL: String = "") {
        base.withHandle { handle in
            script.withCString { code in
                sourceURL.withCString { ncef_browser_execute_javascript(handle, code, $0) }
            }
        }
    }

    /// Chromium's zoom level: 0 is 100%, each step of 1 is 20% more or less.
    var zoomLevel: Double {
        get { base.withHandle { ncef_browser_zoom_level($0) } ?? 0 }
        set { base.withHandle { ncef_browser_set_zoom_level($0, newValue) } }
    }

    /// An editing command on the focused frame.
    func perform(_ command: EditCommand) {
        base.withHandle { ncef_browser_edit($0, command.cValue) }
    }

    /// Close the browser. A model that is simply dropped closes its browser
    /// too; this is for closing one the model outlives.
    func close() {
        base.close()
    }
}

extension EditCommand {
    var cValue: ncef_edit_command {
        switch self {
        case .undo:      NCEF_EDIT_UNDO
        case .redo:      NCEF_EDIT_REDO
        case .cut:       NCEF_EDIT_CUT
        case .copy:      NCEF_EDIT_COPY
        case .paste:     NCEF_EDIT_PASTE
        case .selectAll: NCEF_EDIT_SELECT_ALL
        }
    }
}

// MARK: - What CEF reports

/// CEF's `CefDisplayHandler`: what the page looks like from outside. Every
/// method does nothing by default.
@MainActor
public protocol CEFDisplayHandler: AnyObject {
    func addressDidChange(_ url: String)
    func titleDidChange(_ title: String)
    /// 0…1 while loading.
    func loadingProgressDidChange(_ progress: Double)
    func consoleMessage(_ message: String, level: CEFLogSeverity, source: String, line: Int)
}

public extension CEFDisplayHandler {
    func addressDidChange(_ url: String) {}
    func titleDidChange(_ title: String) {}
    func loadingProgressDidChange(_ progress: Double) {}
    func consoleMessage(_ message: String, level: CEFLogSeverity, source: String, line: Int) {}
}

/// CEF's `CefLoadHandler`. Every method does nothing by default.
@MainActor
public protocol CEFLoadHandler: AnyObject {
    func loadingStateDidChange(isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    /// The main frame failed to load `url` — `code` is Chromium's net error
    /// (e.g. -105, name not resolved).
    func loadDidFail(url: String, code: Int, description: String)
}

public extension CEFLoadHandler {
    func loadingStateDidChange(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func loadDidFail(url: String, code: Int, description: String) {}
}

/// CEF's `CefLifeSpanHandler`.
@MainActor
public protocol CEFLifeSpanHandler: AnyObject {
    func browserDidOpen()
    func browserDidClose()
    /// The page asked to open `url` in a new window. There are no new
    /// windows for a windowless browser; by default the page is loaded here
    /// instead.
    func newWindowRequested(_ url: String)
}

public extension CEFLifeSpanHandler {
    func browserDidOpen() {}
    func browserDidClose() {}
}

public extension CEFLifeSpanHandler where Self: CEFBrowser {
    func newWindowRequested(_ url: String) {
        load(url)
    }
}

/// `cef_log_severity_t`, as console messages report it.
public enum CEFLogSeverity: Int, Sendable {
    case `default` = 0, verbose = 1, info = 2, warning = 3, error = 4, fatal = 5, disabled = 99
}

// MARK: - The model

/// Everything `CEFView` needs from a model: a browser, the handlers for what
/// it reports, and — through this protocol's extension — the `TextureSource`
/// side that puts its frames on screen and its input into the page.
///
/// ```swift
/// @MainActor @Observable
/// final class Docs: CEFBrowserModel {
///     @ObservationIgnored let base = CEFBrowserBase(url: "https://example.com")
///     private(set) var title = ""
///
///     func titleDidChange(_ title: String) { self.title = title }
/// }
///
/// CEFView(docs).frame(width: 800, height: 600)
/// ```
///
/// `CEFWebPage` is a ready-made one.
@MainActor
public protocol CEFBrowserModel: CEFBrowser, CEFDisplayHandler, CEFLoadHandler, CEFLifeSpanHandler, TextureSource {}

public extension CEFBrowserModel {
    func textureDidChange(_ texture: ViewTexture) {
        base.attach(to: self)
        base.textureDidChange(texture)
    }

    func textureDidDisappear(_ texture: ViewTexture) {
        base.textureDidDisappear(texture)
    }

    func textureInput(_ event: TextureInputEvent) {
        base.handle(event)
    }
}
