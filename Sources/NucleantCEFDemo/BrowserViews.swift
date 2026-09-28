//
//  BrowserViews.swift
//  NucleantCEFDemo
//
//  The window: tab strip, navigation bar (back, forward, reload/stop, the
//  address field), a loading line, and the selected tab's page.
//

import Foundation
import NucleantUI
import NucleantCEF

@View
struct BrowserScreen {
    @State private var session = BrowserSession(
        firstPage: ProcessInfo.processInfo.environment["NUCLEANT_CEF_DEMO_URL"] ?? testPage,
        // NUCLEANT_CEF_DEMO_SOFTWARE=1: CEF's CPU frames instead of IOSurfaces.
        options: CEFBrowserOptions(
            sharedTexture: ProcessInfo.processInfo.environment["NUCLEANT_CEF_DEMO_SOFTWARE"] != "1"
        )
    )

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(session: session)
            if let tab = session.selected {
                NavigationBar(tab: tab)
                LoadingLine(progress: tab.isLoading ? tab.progress : nil)
                // One view for whichever tab is showing: switching tabs hands
                // the view to the other tab's browser, and the one left behind
                // is hidden (CEF stops rendering it) until it is shown again.
                CEFView(tab)
                    .onAppear { Verifier.scheduleIfRequested(session: session) }
            }
        }
        .background(Color.background)
    }
}

// MARK: - Tabs

@View
struct TabStrip {
    let session: BrowserSession

    var body: some View {
        HStack(spacing: 4) {
            ForEach(session.tabs) { tab in
                TabItem(
                    tab: tab,
                    isSelected: tab.id == session.selectedID,
                    select: { session.select(tab) },
                    close: { session.close(tab) }
                )
            }
            IconButton(icon: .plus, isEnabled: true) { session.openTab() }
            Spacer()
        }
        .padding(horizontal: 8, vertical: 6)
        .background(Color.tertiaryBackground)
    }
}

@View
struct TabItem {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            IconView(icon: .close, color: .secondary, lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .onTapGesture(perform: close)
        }
        .padding(horizontal: 10, vertical: 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.secondaryBackground : isHovered ? Color.fill : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
    }
}

// MARK: - Navigation

@View
struct NavigationBar {
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 6) {
            IconButton(icon: .back, isEnabled: tab.canGoBack) { tab.goBack() }
            IconButton(icon: .forward, isEnabled: tab.canGoForward) { tab.goForward() }
            IconButton(icon: tab.isLoading ? .stop : .reload, isEnabled: true) {
                if tab.isLoading { tab.stopLoading() } else { tab.reload() }
            }
            TextField("Search or enter address", text: Bindable(tab).address)
                .font(.system(size: 14))
                .onSubmit { tab.submitAddress() }
            if let error = tab.loadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0xE5484D))
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(horizontal: 8, vertical: 6)
        .background(Color.secondaryBackground)
    }
}

/// A square toolbar button: an icon, lit on hover, dimmed when disabled.
@View
struct IconButton {
    let icon: BrowserIcon
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        IconView(icon: icon, color: isEnabled ? .primary : .tertiary)
            .frame(width: 18, height: 18)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && isEnabled ? Color.fill : Color.clear)
            )
            .onHover { isHovered = $0 }
            .onTapGesture { if isEnabled { action() } }
    }
}

/// A thin line under the navigation bar, filled to the loading progress —
/// empty (but still there, so the page doesn't jump) when nothing is loading.
@View
struct LoadingLine {
    let progress: Double?

    var body: some View {
        HStack(spacing: 0) {
            if let progress {
                Rectangle()
                    .fill(Color(hex: 0x4C8DFF))
                    .relativeSize(width: max(0.02, progress))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 2)
    }
}
