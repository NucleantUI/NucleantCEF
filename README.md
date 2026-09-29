# NucleantCEF

Chromium (CEF) as a NucleantUI view. Pages render off-screen, and every frame is copied GPU to GPU into the view's own Vulkan image.

```swift
import NucleantUI
import NucleantCEF

@View
struct Browser {
    @State private var page = CEFWebPage(url: "https://example.com")

    var body: some View {
        VStack {
            Text(page.title)
            CEFView(page)
        }
    }
}
```

Desktop only, and **macOS x86-64 only** for now. iOS and Android are out of scope, because CEF doesn't run there.

## Build and run

```sh
python3 scripts/fetch_cef.py        # CEF 154 minimal distribution → Dependencies/ (~140 MB, pinned + checksummed)
swift build                          # builds the helper executable too — run `swift build`, not just `swift run`
.build/debug/NucleantCEFDemo
```

The demo is a tabbed browser:
- **Tabs:** a tab strip with close buttons and a new-tab button; `target=_blank` links open as new tabs.
- **Navigation:** back, forward, and reload/stop.
- **Address field:** an editable `TextField`. Addresses load as typed, and anything else is searched on DuckDuckGo.
- **Loading:** a loading line, and load errors shown in the bar.

The first tab opens a built-in test page; every tab is a full browser.

- `NUCLEANT_CEF_DEMO_URL=<url>` opens another page in the first tab.
- `NUCLEANT_CEF_DEMO_SOFTWARE=1` switches to CEF's CPU frames.
- `NUCLEANT_CEF_DEMO_VERIFY=<file.png>` runs the self-check described below, saves frames, and quits.

Only one instance of an app can use a CEF profile at a time; a second launch is handed to the first and gets no browser. Point `NUCLEANT_CEF_ROOT_CACHE` somewhere else to run a second one.

## How frames get to the screen

CEF's `OnAcceleratedPaint` hands over each frame as an **IOSurface from a pool of two**. It's valid only until the callback returns, and CEF recycles it for the next frame straight after. If you sample that surface later, you read a frame Chromium is already rewriting. That's the flicker and tearing a direct-sampling approach runs into.

So each frame is copied inside the callback:

1. **Import.** The IOSurface is imported as a VkImage via `VK_EXT_metal_objects` (`VkImportMetalIOSurfaceInfoEXT`). Imports are cached per surface, since the pool keeps presenting the same two.
2. **Copy.** `vkCmdCopyImage` copies it into an image the view owns (`ExternalTextureNode`, in NucleantVulkan). The copy is submitted on the **same queue** as the compositor and waited on with a fence before the callback returns.
3. **Order.** Queue order plus the copy's barriers means a composite already in flight finishes reading the previous frame first, and the next composite sees the whole new frame.

With shared textures off, `OnPaint` gives a CPU buffer instead. It goes through the same node via a staging buffer.

Measured on this machine (AMD RX 580, macOS 26):

| Path | Copy per frame | Frames |
|---|---|---|
| GPU (IOSurface) | 0.33–0.36 ms average, < 1.7 ms worst | ~60 fps, 0 fell back to CPU |
| CPU fallback | 1.5 ms average | |

The self-check samples the texture 90 times while the test page animates. In every run, every sample held an intact frame (no tearing) and a new one (no stale frames).

It then drives the real UI with AppKit events (`NSApp.sendEvent`, the path real input takes) and checks each result:
- resizing the window
- typing into the page
- a `<select>` popup
- the address bar: typing, ⌘A through the Edit menu, then Return
- opening a second tab and switching back.

## Layers

| Where | What |
|---|---|
| `NucleantVulkan` | `ExternalTextureNode`: an image written from outside the engine, by IOSurface or CPU pixels, synchronously. |
| `NucleantUI` | `TextureView(source:)` plus the `TextureSource` protocol. It's a view whose pixels come from an object outside the view tree, told its size and scale, and fed pointer and key input. |
| `NucleantUI` | `TextField` and `.onSubmit`, in SwiftUI's shape. Key focus goes to whichever view was last pressed (a text field or a `TextureView`), and the Edit menu's commands follow it. |
| `CNucleantCEF` | A small C API (`ncef.h`) over CEF's C++ wrapper. Callbacks carry an `Unmanaged` pointer to the Swift side. |
| `CEFWrapper` | CEF's `libcef_dll_wrapper`, compiled straight from the distribution. No CMake step. |
| `NucleantCEFHelper` | The sub-process executable (renderer, GPU, utility). In a renderer it installs `window.cefQuery`. |
| `NucleantCEF` | The Swift API: `CEFRuntime`, the protocols, `CEFWebPage`, `CEFView`. |

### Protocols

Same shape as NucleantThorVG's `ThorPaint` / `ThorShape`: a protocol names the handle (`base: CEFBrowserBase`), and its extension provides the API.

- **`CEFBrowser`** covers commands: `load`, `goBack`, `goForward`, `reload`, `stopLoading`, `evaluateJavaScript`, `zoomLevel`, `perform(.copy)` and so on.
- **`CEFDisplayHandler`, `CEFLoadHandler`, `CEFLifeSpanHandler`** cover what CEF reports. Every method has a no-op default.
- **`CEFQueryHandler`** receives the page's calls to `window.cefQuery`, CEF's message router and its counterpart of WebKit's script message handlers. Return true from `queryReceived` to take a query, then answer it through the `CEFQuery`, straight away or later. A query that isn't taken fails on the page with -1, which is the default.
- **`CEFBrowserModel`** combines them all with `TextureSource`. Any `@Observable` class conforming to it works with `CEFView`. `CEFWebPage` is the ready-made one.

## Runtime

- CEF starts on the first browser and shuts down when the app terminates.
- Its message loop runs through the external pump on the main run loop, in common modes.
- The stock `NSApplication` is given `CefAppProtocol` at runtime, so apps need no subclass.
- The framework, helper and cache paths default to what `swift build` produces. Override them through `CEFRuntime.configuration` or the environment variables `NUCLEANT_CEF_FRAMEWORK_DIR` and `NUCLEANT_CEF_HELPER`.

## Not done yet

- **App bundles.** Nothing yet copies the framework and helper into a `.app`. Paths are resolved for `swift build` output.
- **Retina.** Only tested at 1× (the display here is 1×). The code follows the view's scale, but that path hasn't been run.
- **Input gaps.**
  - Left button only, since NucleantUI's pointer events carry no button.
  - No IME composition.
  - Right-click still goes to NucleantUI's context menus.
- **Browser shortcuts.** No ⌘T / ⌘W / ⌘L yet, and a new tab doesn't focus the address field. NucleantUI has no programmatic focus (`@FocusState`) yet.
- **`TextField` limits.** No undo, no double-click word selection, and the caret doesn't blink.
- **Sandbox.** It's off (`no_sandbox`). Enabling it needs `cef_sandbox` and bundled helpers.
