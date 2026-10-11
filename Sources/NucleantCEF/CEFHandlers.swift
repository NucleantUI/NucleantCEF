//
//  CEFHandlers.swift
//  NucleantCEF
//
//  A model's handlers, as closures — how either platform's `CEFBrowserBase`
//  reaches its model without being generic over it.
//

/// The handlers of a `CEFBrowserModel`, bound once by
/// `CEFBrowserBase.attach(to:)`. Weakly: the model holds the base, not the
/// other way round.
@MainActor
struct CEFHandlers {
    var addressDidChange: (String) -> Void
    var titleDidChange: (String) -> Void
    var loadingProgressDidChange: (Double) -> Void
    var consoleMessage: (String, CEFLogSeverity, String, Int) -> Void
    var loadingStateDidChange: (Bool, Bool, Bool) -> Void
    var loadDidFail: (String, Int, String) -> Void
    var browserDidOpen: () -> Void
    var browserDidClose: () -> Void
    var newWindowRequested: (String) -> Void
    var queryReceived: (CEFQuery) -> Bool
    var queryCanceled: (Int64) -> Void

    init<Model: CEFBrowserModel>(_ model: Model) {
        addressDidChange = { [weak model] in model?.addressDidChange($0) }
        titleDidChange = { [weak model] in model?.titleDidChange($0) }
        loadingProgressDidChange = { [weak model] in model?.loadingProgressDidChange($0) }
        consoleMessage = { [weak model] in model?.consoleMessage($0, level: $1, source: $2, line: $3) }
        loadingStateDidChange = { [weak model] in
            model?.loadingStateDidChange(isLoading: $0, canGoBack: $1, canGoForward: $2)
        }
        loadDidFail = { [weak model] in model?.loadDidFail(url: $0, code: $1, description: $2) }
        browserDidOpen = { [weak model] in model?.browserDidOpen() }
        browserDidClose = { [weak model] in model?.browserDidClose() }
        newWindowRequested = { [weak model] in model?.newWindowRequested($0) }
        queryReceived = { [weak model] in model?.queryReceived($0) ?? false }
        queryCanceled = { [weak model] in model?.queryCanceled(id: $0) }
    }
}
