//
//  CEFBrowserBase.swift
//  NucleantCEF
//
//  One CEF browser, and the glue between it and a `TextureView`:
//
//    * Frames. CEF renders off-screen and hands each frame over in
//      `OnAcceleratedPaint` as an IOSurface from a pool of two, valid only
//      until the callback returns. The frame is copied into the view's
//      texture right there, GPU to GPU (`ViewTexture.write(ioSurface:)`,
//      which returns once the copy has finished) — so the surface is never
//      touched after CEF takes it back, and the composite only ever samples
//      a whole frame in a texture nothing else writes. With shared textures
//      off, `OnPaint`'s CPU buffer takes the same route through the CPU
//      fallback write.
//    * Size. The browser's view is the texture's size, in points, at the
//      texture's scale: CEF asks (`GetViewRect` / `GetScreenInfo`) and is
//      told when either changes.
//    * Input. `TextureView` passes pointer and key input over the view; it
//      is translated into CEF's mouse and key events here.
//    * Events. CEF's handler callbacks go to the model through closures
//      bound once, generically, by `attach(to:)`.
//
//  C callbacks reach this object through an unretained pointer — the browser
//  handle never outlives it (`isolated deinit` releases the handle, which
//  stops every callback), so no retain is needed to keep it valid.
//

import AppKit
import IOSurface
import NucleantUI
import CNucleantCEF

/// How a browser renders.
public struct CEFBrowserOptions: Sendable {
    /// GPU frames (IOSurfaces) when true — the fast path. False takes CEF's
    /// CPU buffer instead, for a machine where the GPU path misbehaves.
    public var sharedTexture: Bool
    /// Frames per second, 1…60.
    public var frameRate: Int
    /// Page background, ARGB, shown where the page draws nothing. Opaque
    /// white is a browser's usual; clear lets the view behind show through.
    public var backgroundColor: UInt32

    public init(sharedTexture: Bool = true, frameRate: Int = 60, backgroundColor: UInt32 = 0xFFFF_FFFF) {
        self.sharedTexture = sharedTexture
        self.frameRate = frameRate
        self.backgroundColor = backgroundColor
    }
}

/// What a browser's frames have cost so far — for telling the GPU path from
/// the CPU fallback, and for seeing what a frame's copy takes.
public struct CEFFrameStatistics: Sendable {
    /// Frames that arrived as IOSurfaces and were copied GPU to GPU.
    public var acceleratedFrames = 0
    /// Frames that arrived as CPU buffers.
    public var softwareFrames = 0
    /// Time spent copying frames into the view's texture, waiting for the
    /// GPU included, in seconds — in total, and the longest single copy.
    public var totalCopyTime: Double = 0
    public var longestCopyTime: Double = 0

    public var averageCopyTime: Double {
        let frames = acceleratedFrames + softwareFrames
        return frames > 0 ? totalCopyTime / Double(frames) : 0
    }
}

@MainActor
public final class CEFBrowserBase {

    public let options: CEFBrowserOptions

    /// The browser, once `ncef_browser_create` has been called — CEF finishes
    /// making it asynchronously (`isOpen`).
    private var handle: OpaquePointer?

    /// Created and not yet closed.
    public private(set) var isOpen = false

    /// What to load when the browser is made.
    private var initialURL: String

    /// Every live base, for closing them all at shutdown.
    private static var live: [ObjectIdentifier: Unmanaged<CEFBrowserBase>] = [:]

    public init(url: String = "about:blank", options: CEFBrowserOptions = CEFBrowserOptions()) {
        self.initialURL = url
        self.options = options
        CEFBrowserBase.live[ObjectIdentifier(self)] = Unmanaged.passUnretained(self)
    }

    isolated deinit {
        CEFBrowserBase.live[ObjectIdentifier(self)] = nil
        if let handle {
            ncef_browser_release(handle)
            if isOpen { CEFRuntime.openBrowsers -= 1 }
        }
    }

    // MARK: - Model binding

    /// The model's handlers, as closures bound once by `attach(to:)`.
    private struct Handlers {
        var addressDidChange: (String) -> Void
        var titleDidChange: (String) -> Void
        var loadingProgressDidChange: (Double) -> Void
        var consoleMessage: (String, CEFLogSeverity, String, Int) -> Void
        var loadingStateDidChange: (Bool, Bool, Bool) -> Void
        var loadDidFail: (String, Int, String) -> Void
        var browserDidOpen: () -> Void
        var browserDidClose: () -> Void
        var newWindowRequested: (String) -> Void
    }

    private var handlers: Handlers?

    /// Route CEF's events to `model`'s handlers. Weakly: the model holds this
    /// base, not the other way round. Once per base.
    func attach<Model: CEFBrowserModel>(to model: Model) {
        guard handlers == nil else { return }
        handlers = Handlers(
            addressDidChange: { [weak model] in model?.addressDidChange($0) },
            titleDidChange: { [weak model] in model?.titleDidChange($0) },
            loadingProgressDidChange: { [weak model] in model?.loadingProgressDidChange($0) },
            consoleMessage: { [weak model] in model?.consoleMessage($0, level: $1, source: $2, line: $3) },
            loadingStateDidChange: { [weak model] in
                model?.loadingStateDidChange(isLoading: $0, canGoBack: $1, canGoForward: $2)
            },
            loadDidFail: { [weak model] in model?.loadDidFail(url: $0, code: $1, description: $2) },
            browserDidOpen: { [weak model] in model?.browserDidOpen() },
            browserDidClose: { [weak model] in model?.browserDidClose() },
            newWindowRequested: { [weak model] in model?.newWindowRequested($0) }
        )
    }

    // MARK: - Commands

    /// `body` with the browser handle, once the browser exists.
    @discardableResult
    func withHandle<R>(_ body: (OpaquePointer) -> R) -> R? {
        guard isOpen, let handle else { return nil }
        return body(handle)
    }

    func load(_ url: String) {
        if let handle {
            url.withCString { ncef_browser_load_url(handle, $0) }
        } else {
            initialURL = url
        }
    }

    func close() {
        guard let handle else { return }
        ncef_browser_close(handle, 0)
    }

    static func closeAll() {
        for base in live.values {
            let base = base.takeUnretainedValue()
            if let handle = base.handle { ncef_browser_close(handle, 1) }
        }
    }

    // MARK: - The view's texture

    /// The texture frames are written into — `nil` while no view shows this
    /// browser.
    public private(set) var texture: ViewTexture?

    /// The view's size in points, rounded up — the browser's view rect.
    private var viewSize: (width: Int, height: Int) = (1, 1)
    private var scale: Double = 1

    func textureDidChange(_ texture: ViewTexture) {
        let shown = self.texture == nil
        self.texture = texture
        let size = (
            width: max(1, Int(texture.size.width.rounded(.up))),
            height: max(1, Int(texture.size.height.rounded(.up)))
        )
        let resized = size != viewSize
        let rescaled = texture.scale != scale
        viewSize = size
        scale = texture.scale

        guard let handle else {
            create()
            return
        }
        guard isOpen else { return }  // it asks for the size itself once made
        if rescaled { ncef_browser_notify_screen_info_changed(handle) }
        if resized || rescaled { ncef_browser_was_resized(handle) }
        if shown {
            ncef_browser_was_hidden(handle, 0)
            // The new texture holds nothing yet; a page at rest would not
            // paint again on its own.
            ncef_browser_invalidate(handle)
        }
    }

    func textureDidDisappear(_ texture: ViewTexture) {
        guard self.texture === texture else { return }
        self.texture = nil
        popup = nil
        if let handle, isOpen {
            ncef_browser_was_hidden(handle, 1)
        }
    }

    // MARK: - Popups

    /// A `<select>` list or similar: drawn by CEF separately from the view,
    /// over it, at `rect` (points). Its pixels are kept on the CPU — a popup
    /// is small, and the view's frames keep arriving under it, each needing
    /// the popup drawn over again after the IOSurface it came in is gone.
    private struct Popup {
        var rect: (x: Int, y: Int, width: Int, height: Int)
        var pixels: [UInt8] = []
        var pixelWidth = 0
        var pixelHeight = 0
    }

    private var popup: Popup?

    fileprivate func popupShow(_ show: Bool) {
        if show {
            if popup == nil { popup = Popup(rect: (0, 0, 0, 0)) }
        } else {
            popup = nil
            // Repaint what the popup covered.
            if let handle, isOpen { ncef_browser_invalidate(handle) }
        }
    }

    fileprivate func popupSize(x: Int, y: Int, width: Int, height: Int) {
        if popup == nil { popup = Popup(rect: (x, y, width, height)) }
        popup?.rect = (x, y, width, height)
    }

    /// The popup's pixels, drawn over the view at its rect.
    private func drawPopup() {
        guard let popup, let texture, popup.pixelWidth > 0 else { return }
        popup.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.write(
                bgra: base,
                width: popup.pixelWidth,
                height: popup.pixelHeight,
                bytesPerRow: popup.pixelWidth * 4,
                x: Int((Double(popup.rect.x) * scale).rounded()),
                y: Int((Double(popup.rect.y) * scale).rounded())
            )
        }
    }

    private func storePopup(bgra: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        guard popup != nil else { return }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                (destination.baseAddress! + row * width * 4)
                    .copyMemory(from: bgra + row * bytesPerRow, byteCount: width * 4)
            }
        }
        popup?.pixels = pixels
        popup?.pixelWidth = width
        popup?.pixelHeight = height
    }

    // MARK: - Frames

    public private(set) var statistics = CEFFrameStatistics()

    /// Time `copy`, into `statistics`.
    private func measure(_ copy: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        copy()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        statistics.totalCopyTime += elapsed
        statistics.longestCopyTime = max(statistics.longestCopyTime, elapsed)
    }

    fileprivate func acceleratedPaint(element: Int32, surface: UnsafeMutableRawPointer) {
        if element == Int32(NCEF_PAINT_POPUP) {
            let ref = Unmanaged<IOSurfaceRef>.fromOpaque(surface).takeUnretainedValue()
            IOSurfaceLock(ref, .readOnly, nil)
            storePopup(
                bgra: IOSurfaceGetBaseAddress(ref),
                width: IOSurfaceGetWidth(ref),
                height: IOSurfaceGetHeight(ref),
                bytesPerRow: IOSurfaceGetBytesPerRow(ref)
            )
            IOSurfaceUnlock(ref, .readOnly, nil)
        } else if let texture {
            statistics.acceleratedFrames += 1
            measure { texture.write(ioSurface: surface) }
        }
        drawPopup()
    }

    fileprivate func paint(element: Int32, buffer: UnsafeRawPointer, width: Int, height: Int) {
        if element == Int32(NCEF_PAINT_POPUP) {
            storePopup(bgra: buffer, width: width, height: height, bytesPerRow: width * 4)
        } else if let texture {
            statistics.softwareFrames += 1
            measure { texture.write(bgra: buffer, width: width, height: height, bytesPerRow: width * 4) }
        }
        drawPopup()
    }

    // MARK: - Browser life

    private func create() {
        guard handle == nil, CEFRuntime.start() else { return }
        var callbacks = CEFBrowserBase.callbacks
        callbacks.userdata = Unmanaged.passUnretained(self).toOpaque()
        var browserOptions = ncef_browser_options(
            shared_texture: options.sharedTexture ? 1 : 0,
            frame_rate: Int32(options.frameRate),
            background_color: options.backgroundColor
        )
        handle = initialURL.withCString { ncef_browser_create($0, &callbacks, &browserOptions) }
        if handle == nil {
            print("NucleantCEF: creating a browser for \(initialURL) failed")
        }
    }

    fileprivate func afterCreated() {
        isOpen = true
        CEFRuntime.openBrowsers += 1
        if texture == nil, let handle {
            ncef_browser_was_hidden(handle, 1)
        }
        handlers?.browserDidOpen()
    }

    fileprivate func beforeClose() {
        if isOpen { CEFRuntime.openBrowsers -= 1 }
        isOpen = false
        if let handle {
            ncef_browser_release(handle)
            self.handle = nil
        }
        handlers?.browserDidClose()
    }

    // MARK: - Input

    /// The last pointer position over the view, in points — where wheel
    /// events land.
    private var pointer = Point(x: 0, y: 0)
    private var buttonDown = false

    /// Consecutive presses close together in time and place are one multi-
    /// click (a double click selects a word), as AppKit counts them.
    private var clickCount = 1
    private var lastClick: (time: TimeInterval, point: Point)?

    func handle(_ event: TextureInputEvent) {
        guard let handle, isOpen else { return }
        switch event {
        case .pointerMoved(let point):
            pointer = point
            ncef_browser_send_mouse_move(handle, Int32(point.x), Int32(point.y), modifiers(), 0)
        case .pointerExited:
            ncef_browser_send_mouse_move(handle, Int32(pointer.x), Int32(pointer.y), modifiers(), 1)
            NSCursor.arrow.set()
        case .pointerDown(let point):
            pointer = point
            buttonDown = true
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick,
               now - last.time <= NSEvent.doubleClickInterval,
               abs(last.point.x - point.x) <= 4, abs(last.point.y - point.y) <= 4 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClick = (now, point)
            ncef_browser_send_mouse_click(
                handle, Int32(point.x), Int32(point.y), modifiers(),
                Int32(NCEF_MOUSE_BUTTON_LEFT), 0, Int32(clickCount)
            )
        case .pointerDragged(let point):
            pointer = point
            ncef_browser_send_mouse_move(handle, Int32(point.x), Int32(point.y), modifiers(), 0)
        case .pointerUp(let point, _):
            pointer = point
            buttonDown = false
            ncef_browser_send_mouse_click(
                handle, Int32(point.x), Int32(point.y), modifiers(),
                Int32(NCEF_MOUSE_BUTTON_LEFT), 1, Int32(clickCount)
            )
        case .scroll(let dx, let dy):
            // Already in points — AppKit's precise deltas, or wheel lines
            // converted — which is what CEF expects with this flag.
            ncef_browser_send_mouse_wheel(
                handle, Int32(pointer.x), Int32(pointer.y),
                modifiers() | UInt32(NCEF_EVENTFLAG_PRECISION_SCROLLING_DELTA),
                Int32(dx.rounded()), Int32(dy.rounded())
            )
        case .keyDown(let keyCode, let characters, let held):
            keyDown(handle, keyCode: keyCode, characters: characters, held: held)
        case .keyUp(let keyCode, let characters, let held):
            sendKey(handle, type: NCEF_KEYEVENT_KEYUP, keyCode: keyCode, held: held,
                    character: characters?.utf16.first ?? 0)
        case .focusChanged(let focused):
            ncef_browser_set_focus(handle, focused ? 1 : 0)
        case .edit(let command):
            ncef_browser_edit(handle, command.cValue)
        }
    }

    private func keyDown(_ handle: OpaquePointer, keyCode: UInt16, characters: String?, held: EventModifiers) {
        // ⌘-shortcuts are menu commands in a windowed browser; a windowless
        // one has no menu to receive them.
        if held.contains(.command),
           let command = CEFKeyMap.editCommand(forKeyCode: keyCode, shift: held.contains(.shift)) {
            ncef_browser_edit(handle, command.cValue)
            return
        }
        sendKey(handle, type: NCEF_KEYEVENT_RAWKEYDOWN, keyCode: keyCode, held: held,
                character: characters?.utf16.first ?? 0)
        // The text a key types is its own event. Not for ⌘/⌃ chords, and not
        // for the function keys (arrows, F-keys…), which AppKit reports as
        // characters in the private-use range U+F700–U+F8FF.
        guard !held.contains(.command), !held.contains(.control),
              let characters, !characters.isEmpty
        else { return }
        for unit in characters.utf16 where !(0xF700...0xF8FF).contains(unit) {
            sendKey(handle, type: NCEF_KEYEVENT_CHAR, keyCode: keyCode, held: held, character: unit)
        }
    }

    private func sendKey(_ handle: OpaquePointer, type: Int, keyCode: UInt16, held: EventModifiers, character: UInt16) {
        ncef_browser_send_key_event(
            handle,
            Int32(type),
            keyModifiers(held),
            Int32(CEFKeyMap.windowsKeyCode(forKeyCode: keyCode, character: character)),
            Int32(keyCode),
            0,
            character,
            character
        )
    }

    /// CEF's `cef_event_flags_t` for a key event's modifiers.
    private func keyModifiers(_ held: EventModifiers) -> UInt32 {
        var result: UInt32 = 0
        if held.contains(.shift)   { result |= UInt32(NCEF_EVENTFLAG_SHIFT_DOWN) }
        if held.contains(.control) { result |= UInt32(NCEF_EVENTFLAG_CONTROL_DOWN) }
        if held.contains(.option)  { result |= UInt32(NCEF_EVENTFLAG_ALT_DOWN) }
        if held.contains(.command) { result |= UInt32(NCEF_EVENTFLAG_COMMAND_DOWN) }
        if NSEvent.modifierFlags.contains(.capsLock) { result |= UInt32(NCEF_EVENTFLAG_CAPS_LOCK_ON) }
        return result
    }

    /// CEF's `cef_event_flags_t` for the keys held now and the button down —
    /// for pointer events, which carry no modifiers of their own.
    private func modifiers() -> UInt32 {
        let flags = NSEvent.modifierFlags
        var result: UInt32 = 0
        if flags.contains(.shift)    { result |= UInt32(NCEF_EVENTFLAG_SHIFT_DOWN) }
        if flags.contains(.control)  { result |= UInt32(NCEF_EVENTFLAG_CONTROL_DOWN) }
        if flags.contains(.option)   { result |= UInt32(NCEF_EVENTFLAG_ALT_DOWN) }
        if flags.contains(.command)  { result |= UInt32(NCEF_EVENTFLAG_COMMAND_DOWN) }
        if flags.contains(.capsLock) { result |= UInt32(NCEF_EVENTFLAG_CAPS_LOCK_ON) }
        if buttonDown                { result |= UInt32(NCEF_EVENTFLAG_LEFT_MOUSE_BUTTON) }
        return result
    }

    // MARK: - C callbacks

    /// The callback table every browser shares; each gets its own `userdata`.
    private static var callbacks: ncef_client_callbacks {
        var callbacks = ncef_client_callbacks()
        callbacks.view_size = { userdata, width, height in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated {
                width?.pointee = Int32(base.viewSize.width)
                height?.pointee = Int32(base.viewSize.height)
            }
        }
        callbacks.scale_factor = { userdata in
            let base = CEFBrowserBase.from(userdata)
            return MainActor.assumeIsolated { base.scale }
        }
        callbacks.accelerated_paint = { userdata, element, surface, _ in
            guard let surface else { return }
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated { base.acceleratedPaint(element: element, surface: surface) }
        }
        callbacks.paint = { userdata, element, buffer, width, height in
            guard let buffer else { return }
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated {
                base.paint(element: element, buffer: buffer, width: Int(width), height: Int(height))
            }
        }
        callbacks.popup_show = { userdata, show in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated { base.popupShow(show != 0) }
        }
        callbacks.popup_size = { userdata, x, y, width, height in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated {
                base.popupSize(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
            }
        }
        callbacks.address_change = { userdata, url in
            let base = CEFBrowserBase.from(userdata)
            let url = String(cString: url!)
            MainActor.assumeIsolated { base.handlers?.addressDidChange(url) }
        }
        callbacks.title_change = { userdata, title in
            let base = CEFBrowserBase.from(userdata)
            let title = String(cString: title!)
            MainActor.assumeIsolated { base.handlers?.titleDidChange(title) }
        }
        callbacks.loading_progress = { userdata, progress in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated { base.handlers?.loadingProgressDidChange(progress) }
        }
        callbacks.cursor_change = { _, cursor, _ in
            guard let cursor else { return }
            MainActor.assumeIsolated {
                Unmanaged<NSCursor>.fromOpaque(cursor).takeUnretainedValue().set()
            }
        }
        callbacks.console_message = { userdata, level, message, source, line in
            let base = CEFBrowserBase.from(userdata)
            let message = String(cString: message!)
            let source = String(cString: source!)
            MainActor.assumeIsolated {
                base.handlers?.consoleMessage(message, CEFLogSeverity(rawValue: Int(level)) ?? .default, source, Int(line))
            }
        }
        callbacks.loading_state_change = { userdata, loading, back, forward in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated { base.handlers?.loadingStateDidChange(loading != 0, back != 0, forward != 0) }
        }
        callbacks.load_error = { userdata, code, text, url in
            let base = CEFBrowserBase.from(userdata)
            let text = String(cString: text!)
            let url = String(cString: url!)
            MainActor.assumeIsolated { base.handlers?.loadDidFail(url, Int(code), text) }
        }
        callbacks.after_created = { userdata in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated { base.afterCreated() }
        }
        callbacks.before_close = { userdata in
            let base = CEFBrowserBase.from(userdata)
            MainActor.assumeIsolated { base.beforeClose() }
        }
        callbacks.before_popup = { userdata, url in
            let base = CEFBrowserBase.from(userdata)
            let url = String(cString: url!)
            // Not from inside the callback: loading here would re-enter the
            // browser while it is still deciding about the popup.
            DispatchQueue.main.async { [weak base] in
                MainActor.assumeIsolated { base?.handlers?.newWindowRequested(url) }
            }
        }
        return callbacks
    }

    private nonisolated static func from(_ userdata: UnsafeMutableRawPointer?) -> CEFBrowserBase {
        Unmanaged<CEFBrowserBase>.fromOpaque(userdata!).takeUnretainedValue()
    }
}
