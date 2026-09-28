//
//  CEFWebPage.swift
//  NucleantCEF
//
//  A ready-made browser model: CEF's display and load events kept in
//  observable properties, for a browser UI to read — an address bar reads
//  `url`, a tab its `title`, a progress bar `estimatedProgress`.
//

import Observation

/// One web page in a CEF browser.
///
/// ```swift
/// @State private var page = CEFWebPage(url: "https://example.com")
///
/// var body: some View {
///     VStack {
///         Text(page.title)
///         CEFView(page)
///     }
/// }
/// ```
///
/// Views read the properties and rebuild when the ones they read change;
/// commands (`load`, `goBack`, `reload`, …) come from `CEFBrowser`.
@MainActor
@Observable
public final class CEFWebPage: CEFBrowserModel {

    @ObservationIgnored public let base: CEFBrowserBase

    /// The main frame's address.
    public private(set) var url: String
    public private(set) var title = ""
    public private(set) var isLoading = false
    /// 0…1 while loading, 1 once loaded.
    public private(set) var estimatedProgress = 0.0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// The main frame's last failed load, cleared when the next one starts.
    public private(set) var lastError: LoadError?

    public struct LoadError: Sendable, Equatable {
        public let url: String
        /// Chromium's net error code, e.g. -105 (name not resolved).
        public let code: Int
        public let description: String
    }

    public init(url: String = "about:blank", options: CEFBrowserOptions = CEFBrowserOptions()) {
        self.url = url
        self.base = CEFBrowserBase(url: url, options: options)
    }

    // MARK: - CEFDisplayHandler

    public func addressDidChange(_ url: String) {
        self.url = url
    }

    public func titleDidChange(_ title: String) {
        self.title = title
    }

    public func loadingProgressDidChange(_ progress: Double) {
        estimatedProgress = progress
    }

    // MARK: - CEFLoadHandler

    public func loadingStateDidChange(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if isLoading, !self.isLoading { lastError = nil }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    public func loadDidFail(url: String, code: Int, description: String) {
        lastError = LoadError(url: url, code: code, description: description)
    }
}
