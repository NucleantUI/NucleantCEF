//
//  Browser.swift
//  NucleantCEFDemo
//
//  The browser's data: a session of tabs, each tab its own CEF browser. The
//  tab is a `CEFBrowserModel` of its own rather than a `CEFWebPage`, because
//  it keeps something a page model has no reason to — the address bar's text,
//  which follows the page until the user edits it.
//

import Foundation
import Observation
import NucleantCEF

/// The open tabs, and which one is showing.
@MainActor
@Observable
final class BrowserSession {
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedID: Int?

    private let options: CEFBrowserOptions

    var selected: BrowserTab? {
        tabs.first { $0.id == selectedID }
    }

    init(firstPage: String, options: CEFBrowserOptions) {
        self.options = options
        openTab(firstPage)
    }

    /// A new tab loading `url`, shown at once — after the current tab.
    func openTab(_ url: String = BrowserTab.newTabPage) {
        let tab = BrowserTab(url: url, options: options, session: self)
        if let current = tabs.firstIndex(where: { $0.id == selectedID }) {
            tabs.insert(tab, at: current + 1)
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
    }

    /// Close `tab`, showing its neighbour if it was the one showing. The last
    /// tab closing leaves a fresh one, as a browser window would.
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tab.close()
        if tabs.isEmpty {
            openTab()
        } else if selectedID == tab.id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }
}

/// One tab: a CEF browser, what it reports, and the address bar's text.
@MainActor
@Observable
final class BrowserTab: CEFBrowserModel, Identifiable {
    static let newTabPage = "https://duckduckgo.com"

    let id: Int
    @ObservationIgnored let base: CEFBrowserBase
    @ObservationIgnored private weak var session: BrowserSession?

    private(set) var url: String
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The main frame's last failure, cleared by the next load.
    private(set) var loadError: String?

    /// What the address bar shows and edits. Follows the page's address on
    /// every navigation; the user's edits last until they submit or the page
    /// moves on.
    var address: String

    private static var nextID = 0

    init(url: String, options: CEFBrowserOptions, session: BrowserSession) {
        BrowserTab.nextID += 1
        self.id = BrowserTab.nextID
        self.url = url
        self.address = BrowserTab.displayAddress(url)
        self.base = CEFBrowserBase(url: url, options: options)
        self.session = session
    }

    /// The tab strip's label.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if isLoading { return "Loading…" }
        return URL(string: url)?.host ?? "New Tab"
    }

    /// Load what was typed into the address bar: an address as it is (a
    /// scheme added when it has none), anything else as a search.
    func submitAddress() {
        let typed = address.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        load(BrowserTab.resolve(typed))
    }

    static func resolve(_ typed: String) -> String {
        if typed.contains("://") || typed.hasPrefix("about:") || typed.hasPrefix("data:") {
            return typed
        }
        let looksLikeHost = !typed.contains(" ")
            && (typed.contains(".") || typed.hasPrefix("localhost"))
        if looksLikeHost {
            return "https://" + typed
        }
        let query = typed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? typed
        return "https://duckduckgo.com/?q=" + query
    }

    /// A `data:` address is the whole page — not something to show or edit.
    private static func displayAddress(_ url: String) -> String {
        url.hasPrefix("data:") ? "" : url
    }

    // MARK: - CEFDisplayHandler

    func addressDidChange(_ url: String) {
        self.url = url
        address = BrowserTab.displayAddress(url)
    }

    func titleDidChange(_ title: String) {
        self.title = title
    }

    func loadingProgressDidChange(_ progress: Double) {
        self.progress = progress
    }

    // MARK: - CEFLoadHandler

    func loadingStateDidChange(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if isLoading, !self.isLoading { loadError = nil }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    func loadDidFail(url: String, code: Int, description: String) {
        // -3 is ERR_ABORTED: a load the user stopped, or one replaced by the
        // next — not a failure worth showing.
        guard code != -3 else { return }
        loadError = "\(description) (\(code))"
    }

    // MARK: - CEFLifeSpanHandler

    /// A link that wants a new window opens a tab instead.
    func newWindowRequested(_ url: String) {
        session?.openTab(url)
    }
}
