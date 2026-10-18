//
//  CEFBrowserBase+Web.swift
//  NucleantCEF
//
//  One browser in the browser build. The page the app runs in is a browser
//  already, so a browser view is not a CEF instance rendering into the view's
//  texture but an <iframe> laid over the view (Platform_Wasm's
//  `BrowserFrame`) — the desktop's is CEFBrowserBase+MacOS.swift:
//
//    * Frames. None pass through the app: the browser draws the page itself,
//      over the canvas. The view's texture stays empty underneath it.
//    * Size and place. The iframe follows the view's frame in the window and
//      is cut to what clips it (`ViewTexture.frame` / `visibleFrame`), on
//      every layout pass that resizes the view (`textureDidChange`) or only
//      moves it (`textureDidMove`).
//    * Input. The iframe takes the pointer and the keys itself — IME,
//      clipboard and context menus included — so nothing comes through
//      `TextureView`.
//    * Events. Loads, console output and `window.cefQuery` come from the
//      page through the frame, to the same handlers as on the desktop.
//
//  What a page in an iframe cannot do: one from another origin cannot be
//  scripted or given `window.cefQuery` (`evaluateJavaScript` and queries are
//  for the app's own pages, as Monaco's is), and many sites refuse to be
//  framed at all. Whatever NucleantUI draws over the view's rect is under the
//  iframe, not over it.
//

#if os(WASI)
import Foundation
import NucleantUI
import Platform_Wasm

@MainActor
public final class CEFBrowserBase {

    public let options: CEFBrowserOptions

    /// The iframe, made when a view first shows this browser.
    private var frame: BrowserFrame?

    /// Created and not yet closed.
    public private(set) var isOpen = false

    /// The address last asked for — loaded once there is a frame.
    private var url: String

    public init(url: String = "about:blank", options: CEFBrowserOptions = CEFBrowserOptions()) {
        self.url = url
        self.options = options
    }

    // MARK: - Model binding

    private var handlers: CEFHandlers?

    /// Route the page's events to `model`'s handlers. Once per base.
    func attach<Model: CEFBrowserModel>(to model: Model) {
        guard handlers == nil else { return }
        handlers = CEFHandlers(model)
    }

    // MARK: - Commands

    func load(_ url: String) {
        self.url = url
        guard let frame else { return }
        startLoading(in: frame)
    }

    func close() {
        guard let frame else { return }
        frame.destroy()
        self.frame = nil
        isOpen = false
        handlers?.browserDidClose()
    }

    /// Back and forward go through the page's own history: the app's own
    /// pages only.
    func goBack() {
        frame?.navigate(.back)
    }

    func goForward() {
        frame?.navigate(.forward)
    }

    func reload(ignoringCache: Bool) {
        guard let frame else { return }
        frame.navigate(ignoringCache ? .reloadIgnoringCache : .reload)
        loadingStarted()
    }

    func stopLoading() {
        frame?.navigate(.stop)
    }

    func evaluateJavaScript(_ script: String, sourceURL: String) {
        // What CEF's `script_url` is for: the name the page's debugger and
        // error messages give the script.
        frame?.evaluate(sourceURL.isEmpty ? script : "\(script)\n//# sourceURL=\(sourceURL)")
    }

    /// Chromium's zoom level: each step is a factor of 1.2.
    var zoomLevel: Double = 0 {
        didSet { frame?.zoom = pow(1.2, zoomLevel) }
    }

    func perform(_ command: EditCommand) {
        let name = switch command {
        case .undo: "undo"
        case .redo: "redo"
        case .cut: "cut"
        case .copy: "copy"
        case .paste: "paste"
        case .selectAll: "selectAll"
        }
        frame?.evaluate("document.execCommand('\(name)')")
    }

    func succeedQuery(_ id: Int64, response: String) {
        frame?.succeed(query: UInt32(truncatingIfNeeded: id), response: response)
    }

    func failQuery(_ id: Int64, code: Int, message: String) {
        frame?.fail(query: UInt32(truncatingIfNeeded: id), code: code, message: message)
    }

    // MARK: - The view's texture

    /// The view's texture — `nil` while no view shows this browser. Nothing
    /// is written into it: it marks where the iframe goes.
    public private(set) var texture: ViewTexture<NucleantRenderNode>?

    /// All zero: no frame passes through the app.
    public private(set) var statistics = CEFFrameStatistics()

    func textureDidChange(_ texture: ViewTexture<NucleantRenderNode>) {
        self.texture = texture
        if frame == nil { create() }
        place(texture)
    }

    func textureDidMove(_ texture: ViewTexture<NucleantRenderNode>) {
        guard self.texture === texture else { return }
        place(texture)
    }

    func textureDidDisappear(_ texture: ViewTexture<NucleantRenderNode>) {
        guard self.texture === texture else { return }
        self.texture = nil
        updateVisibility()
    }

    private func place(_ texture: ViewTexture<NucleantRenderNode>) {
        guard let frame, let window = texture.browserWindowID else { return }
        let rect = texture.frame, visible = texture.visibleFrame
        frame.place(
            inWindow: window,
            frame: SIMD4(rect.x, rect.y, rect.width, rect.height),
            visible: SIMD4(visible.x, visible.y, visible.width, visible.height)
        )
        updateVisibility()
    }

    /// Shown while a view shows it, once it has a page — an empty iframe
    /// would only cover what the app draws there instead (a notice that the
    /// page could not be found, say).
    private func updateVisibility() {
        frame?.isHidden = texture == nil || url == "about:blank"
    }

    // MARK: - Input

    /// Pointer and keys never get here — the iframe is over the view and
    /// takes them itself. Only the app's own Edit commands do.
    func handle(_ event: TextureInputEvent) {
        if case .edit(let command) = event { perform(command) }
    }

    // MARK: - Browser life

    private func create() {
        CEFRuntime.start()
        let frame = BrowserFrame(background: options.backgroundColor, queryFunction: "cefQuery")
        // The page calls in on the main thread; there is no other.
        frame.onLoad = { [weak self] url, title in
            MainActor.assumeIsolated { self?.loaded(url: url, title: title) }
        }
        frame.onQuery = { [weak self] id, request, frameURL, persistent in
            MainActor.assumeIsolated {
                self?.received(query: id, request: request, frameURL: frameURL, persistent: persistent)
            }
        }
        frame.onQueryCanceled = { [weak self] id in
            MainActor.assumeIsolated { self?.handlers?.queryCanceled(Int64(id)) }
        }
        frame.onConsoleMessage = { [weak self] level, message, source, line in
            MainActor.assumeIsolated {
                self?.handlers?.consoleMessage(message, CEFLogSeverity(rawValue: level) ?? .default, source, line)
            }
        }
        if zoomLevel != 0 { frame.zoom = pow(1.2, zoomLevel) }
        self.frame = frame
        isOpen = true
        handlers?.browserDidOpen()
        if url != "about:blank" { startLoading(in: frame) }
    }

    private func startLoading(in frame: BrowserFrame) {
        frame.load(url)
        loadingStarted()
        updateVisibility()
    }

    /// An iframe reports no progress and no history: loading is 0 until it
    /// has loaded, and back and forward are never known to be possible.
    private func loadingStarted() {
        handlers?.loadingStateDidChange(true, false, false)
        handlers?.loadingProgressDidChange(0)
    }

    private func loaded(url: String, title: String) {
        handlers?.addressDidChange(url)
        handlers?.titleDidChange(title)
        handlers?.loadingProgressDidChange(1)
        handlers?.loadingStateDidChange(false, false, false)
    }

    private func received(query id: UInt32, request: String, frameURL: String, persistent: Bool) {
        let query = CEFQuery(
            id: Int64(id),
            request: request,
            frameURL: frameURL,
            isMainFrame: true,
            isPersistent: persistent,
            base: self
        )
        if handlers?.queryReceived(query) != true {
            // What CEF's router answers a query no handler took.
            frame?.fail(query: id, code: -1, message: "The query has been canceled")
        }
    }
}
#endif
