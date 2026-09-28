//
//  CEFView.swift
//  NucleantCEF
//
//  A CEF browser as a NucleantUI view.
//

import NucleantUI

/// Shows the browser of `model`, and takes the pointer and keys for it.
///
/// ```swift
/// CEFView(page)
///     .frame(width: 1024, height: 768)
/// ```
///
/// Any `CEFBrowserModel` will do — `CEFWebPage`, or a model of your own that
/// keeps just the events it needs. The browser is made when the view first
/// appears, at the view's size, and follows the view's size and scale from
/// then on; it is hidden (CEF stops rendering it) while no view shows it,
/// and closed when the model goes away.
///
/// Built on `TextureView`: every frame CEF renders is copied, GPU to GPU,
/// into the view's own texture as it arrives, so nothing in the view tree
/// rebuilds for a page to animate. Give it a `.frame` — it takes the space
/// it is offered.
@View
public struct CEFView<Model: CEFBrowserModel> {
    let model: Model

    public init(_ model: Model, _viewID: ViewID = #viewID) {
        self.model = model
        self._viewID = _viewID
    }

    public var body: some View {
        TextureView(source: model)
    }
}
