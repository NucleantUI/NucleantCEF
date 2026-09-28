//
//  Verifier.swift
//  NucleantCEFDemo
//
//  NUCLEANT_CEF_DEMO_VERIFY=<file.png>: exercise the browser end to end,
//  report, and quit. Against the first tab's test page:
//
//  1. Sample the view's texture 90 times while the page animates: the
//     sliding square must be one intact rectangle in every sample (a frame
//     read half-written, or from a surface CEF already recycled, shows it at
//     two positions in different rows), and must move (a stale texture shows
//     the same frame every time).
//  2. Resize the window; the texture must follow.
//  3. Click the page's text field and type — the title must show it.
//  4. Open the page's <select> — its popup is saved in a frame.
//  5. Type an address into the address bar (junk, ⌘A, then a data: URL) and
//     press Return — the page must load it.
//  6. Open a second tab on a blue page, then go back to the first: each must
//     show its own page in the one view.
//
//  Input goes through `NSApp.sendEvent` — the path real events take:
//  `PlatformWindow` → `HostingWindow` → `ViewHost` → the view.
//

import AppKit
import NucleantUI
import NucleantCEF

@MainActor
enum Verifier {
    private static var scheduled = false

    static func scheduleIfRequested(session: BrowserSession) {
        guard !scheduled,
              let path = ProcessInfo.processInfo.environment["NUCLEANT_CEF_DEMO_VERIFY"],
              let tab = session.tabs.first
        else { return }
        scheduled = true
        after(3) {
            sample(tab: tab, remaining: 90, positions: []) {
                save(tab: tab, path: path)
                NSApplication.shared.windows.first?.setContentSize(NSSize(width: 900, height: 600))
                after(2) {
                    checkResize(tab: tab)
                    click(tab: tab, x: 100, y: 180)
                    type("hi")
                }
                after(4) {
                    report("page input", tab.title == "typed:hi", "title '\(tab.title)'")
                    click(tab: tab, x: 40, y: 230)
                }
                after(5.5) {
                    save(tab: tab, path: path.replacingOccurrences(of: ".png", with: "-popup.png"))
                    // Close the popup, then drive the address bar.
                    key(0x35, "\u{1B}")
                    clickAddressBar(tab: tab)
                    type("junk")
                    key(0x00, "a", [.command])
                    type("data:text/html,<title>typed-url</title><body style='background:rgb(0,160,80)'>")
                    key(0x24, "\r")
                }
                after(7.5) {
                    report("address bar", tab.title == "typed-url", "title '\(tab.title)', address '\(tab.address)'")
                    save(tab: tab, path: path.replacingOccurrences(of: ".png", with: "-address.png"))
                    session.openTab("data:text/html,<title>second</title><body style='background:rgb(0,64,255)'>")
                }
                after(9.5) {
                    let second = session.selected
                    report("second tab", second?.title == "second" && centerIs(second, [255, 64, 0]),
                           "title '\(second?.title ?? "-")', center \(center(second).map(String.init(describing:)) ?? "-")")
                    save(tab: second, path: path.replacingOccurrences(of: ".png", with: "-tab2.png"))
                    session.select(tab)
                }
                after(11) {
                    report("back to first tab", centerIs(tab, [80, 160, 0]),
                           "center \(center(tab).map(String.init(describing:)) ?? "-")")
                    let stats = tab.base.statistics
                    print("VERIFY: first tab frames \(stats.acceleratedFrames) GPU, \(stats.softwareFrames) CPU; "
                          + String(format: "copy avg %.3f ms, longest %.3f ms",
                                   stats.averageCopyTime * 1000, stats.longestCopyTime * 1000))
                    // Informational: a real site in a third tab, and the whole
                    // window as it looks — needs the network, and Screen
                    // Recording permission for the screenshot to show anything.
                    session.openTab("https://en.wikipedia.org/wiki/Chromium_Embedded_Framework")
                }
                after(17) {
                    screenshot(path: path.replacingOccurrences(of: ".png", with: "-window.png"))
                    print("VERIFY: third tab '\(session.selected?.title ?? "-")'")
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private static func report(_ check: String, _ passed: Bool, _ detail: String) {
        print("VERIFY: \(check): \(passed ? "PASS" : "FAIL") — \(detail)")
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    // MARK: - Frames

    private static func sample(tab: BrowserTab, remaining: Int, positions: [Int], done: @escaping @MainActor () -> Void) {
        guard remaining > 0 else {
            let distinct = Set(positions).count
            report("frames while animating", positions.count == 90 && distinct > 10,
                   "\(positions.count) of 90 intact, square at \(distinct) distinct positions")
            done()
            return
        }
        guard let texture = tab.base.texture, let read = texture.readPixels() else {
            print("VERIFY: no frame to sample")
            done()
            return
        }
        let next = squarePosition(read, scale: texture.scale).map { positions + [$0] } ?? positions
        after(0.02) { sample(tab: tab, remaining: remaining - 1, positions: next, done: done) }
    }

    /// The square's left edge, if it is one intact rectangle in every row it
    /// spans; logs and returns nil otherwise.
    private static func squarePosition(_ read: (width: Int, height: Int, bgra: [UInt8]), scale: Double) -> Int? {
        let (width, _, bgra) = read
        func isLime(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return bgra[i] < 60 && bgra[i + 1] > 200 && bgra[i + 2] < 60
        }
        let top = Int(30 * scale), bottom = Int(70 * scale)
        var span: (Int, Int)?
        for y in top..<bottom {
            var first = -1, last = -1
            for x in 0..<width where isLime(x, y) {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else {
                print("VERIFY: TORN — row \(y) has no square")
                return nil
            }
            if let span, span != (first, last) {
                print("VERIFY: TORN — row \(y) spans \(first)…\(last), rows above \(span.0)…\(span.1)")
                return nil
            }
            span = (first, last)
        }
        guard let span else { return nil }
        let expected = Int((60 * scale).rounded())
        guard abs(span.1 - span.0 + 1 - expected) <= 1 else {
            print("VERIFY: square is \(span.1 - span.0 + 1) px wide, expected \(expected)")
            return nil
        }
        return span.0
    }

    private static func checkResize(tab: BrowserTab) {
        guard let texture = tab.base.texture, let read = texture.readPixels() else {
            report("resize", false, "no frame after resize")
            return
        }
        let i = ((texture.pixelHeight - 2) * read.width + texture.pixelWidth - 2) * 4
        let corner = Array(read.bgra[i..<i + 4])
        report("resize", corner == [128, 0, 255, 255],
               "view \(texture.pixelWidth)x\(texture.pixelHeight) px in a \(read.width)x\(read.height) texture, bottom-right BGRA \(corner)")
    }

    /// The BGR of the pixel at the view's center.
    private static func center(_ tab: BrowserTab?) -> [UInt8]? {
        guard let texture = tab?.base.texture, let read = texture.readPixels() else { return nil }
        let i = ((texture.pixelHeight / 2) * read.width + texture.pixelWidth / 2) * 4
        return Array(read.bgra[i..<i + 3])
    }

    private static func centerIs(_ tab: BrowserTab?, _ bgr: [UInt8]) -> Bool {
        guard let center = center(tab) else { return false }
        return zip(center, bgr).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
    }

    // MARK: - Input

    /// Click at (`x`, `y`) in the page.
    private static func click(tab: BrowserTab, x: Double, y: Double) {
        guard let content = NSApplication.shared.windows.first?.contentView, let texture = tab.base.texture else { return }
        // The page sits under the toolbar and fills the rest of the window.
        let toolbarHeight = content.bounds.height - texture.size.height
        clickWindow(x: x, yFromTop: toolbarHeight + y)
    }

    /// Click the address field: the navigation bar sits just above the page
    /// (and its 2-point loading line); the field starts after three buttons.
    private static func clickAddressBar(tab: BrowserTab) {
        guard let content = NSApplication.shared.windows.first?.contentView, let texture = tab.base.texture else { return }
        let toolbarHeight = content.bounds.height - texture.size.height
        clickWindow(x: 300, yFromTop: toolbarHeight - 2 - 21)
    }

    private static func clickWindow(x: Double, yFromTop: Double) {
        guard let window = NSApplication.shared.windows.first, let content = window.contentView else { return }
        let location = NSPoint(x: x, y: content.bounds.height - yFromTop)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                NSApplication.shared.sendEvent(event)
            }
        }
    }

    private static func type(_ text: String) {
        for character in text {
            key(0x00, String(character))
        }
    }

    /// Press and release a key. Typing text sends key code 0x00 ("A") with
    /// each character: fields insert by character, and the code means
    /// nothing on its own without ⌘.
    private static func key(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
        guard let window = NSApplication.shared.windows.first else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) {
                NSApplication.shared.sendEvent(event)
            }
        }
    }

    // MARK: - Saving

    /// The window, as it is on screen.
    private static func screenshot(path: String) {
        guard let window = NSApplication.shared.windows.first else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        do {
            try capture.run()
            capture.waitUntilExit()
            print("VERIFY: wrote \(path)")
        } catch {
            print("VERIFY: screenshot failed: \(error)")
        }
    }

    private static func save(tab: BrowserTab?, path: String) {
        guard let (width, height, bgra) = tab?.base.texture?.readPixels() else { return }
        let data = Data(bgra) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("VERIFY: wrote \(path)")
    }
}
