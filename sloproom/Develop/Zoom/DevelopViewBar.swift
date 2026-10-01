//
//  DevelopViewBar.swift
//  sloproom
//
//  Thin bar under the Develop canvas: zoom control (Fit / Fill / 1:1 + menu of levels) with the
//  current zoom, panel toggles and the full-screen preview button.
//

import SwiftUI

struct DevelopViewBar: View {
    let session: DevelopSession
    @Environment(AppModel.self) private var model
    private var zoom: ZoomController { ZoomController.develop }
    private var panels: DevelopPanels { DevelopPanels.shared }
    private var store: ShortcutStore { .shared }

    // The zoom controls are their own views: a pinch changes the zoom every frame, and only the
    // readout's text should update then (not the whole bar / the segmented control).
    var body: some View {
        HStack(spacing: 10) {
            ZoomSegments(zoom: zoom, disabled: session.activeTool == .crop)
            ZoomLevelMenu(zoom: zoom, disabled: session.activeTool == .crop)

            Spacer()

            Button { panels.toggleSidebar(in: .develop) } label: { Image(systemName: "sidebar.left") }
                .iconHelp(panels.sidebarHidden ? "Show Folders" : "Hide Folders", shortcut: .toggleSidebar)
            Button { panels.inspectorHidden.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(store.help(panels.inspectorHidden ? "Show Inspector" : "Hide Inspector", nil) + " — "
                      + store.help("both side panels", .toggleSidePanels))
                .accessibilityLabel(panels.inspectorHidden ? "Show Inspector" : "Hide Inspector")
            Button { panels.toggleLightsOut() } label: { Image(systemName: "rectangle.inset.filled") }
                .iconHelp("Canvas Only: hide all panels", shortcut: .toggleAllPanels)
            Button { FullScreenPreview.shared.show(model: model) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .iconHelp("Full Screen Preview", shortcut: .fullScreenPreview)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

}

/// Fit / Fill / 1:1, plus an extra selected segment for any other level: the preset's label
/// ("200%") or "Custom" for a free (pinch / ⌘-scroll) zoom, so the control only changes when
/// the kind of level changes, not on every pinch frame (the menu next to it shows the %).
private struct ZoomSegments: View {
    let zoom: ZoomController
    let disabled: Bool
    private var store: ShortcutStore { .shared }

    var body: some View {
        let extra = ZoomBarLevels.extraSegment(for: zoom.level)
        Picker("Zoom", selection: Binding(
            get: { extra?.tag ?? zoom.level },
            set: { if $0 != ZoomBarLevels.customTag { zoom.setLevel($0, anchor: nil, remember: true) } }
        )) {
            Text("Fit").tag(ZoomLevel.fit)
            Text("Fill").tag(ZoomLevel.fill)
            Text("1:1").tag(ZoomLevel.ratio(1))
            if let extra { Text(extra.label).tag(extra.tag) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(disabled)
        .segmentHelp(tips(extra: extra != nil))
    }

    private func tips(extra: Bool) -> [String] {
        var tips = [store.help("Fit: whole photo", [.zoomToggle, .zoomFit]), "Fill: photo fills the canvas",
                    store.help("1:1: one image pixel per screen pixel", .zoomToggle)]
        if extra { tips.append("Current zoom level (pinch, ⌘-scroll or the menu)") }
        return tips
    }
}

/// The current zoom ("Fit (23%)", "137%") + a menu of levels.
private struct ZoomLevelMenu: View {
    let zoom: ZoomController
    let disabled: Bool
    private var store: ShortcutStore { .shared }

    var body: some View {
        Menu {
            ForEach(ZoomLevel.steps, id: \.self) { r in
                Button(CanvasViewport.label(.ratio(r))) { zoom.setLevel(.ratio(r), anchor: nil, remember: true) }
            }
            Divider()
            Button(store.help("Zoom In", .zoomIn)) { zoom.step(zoomIn: true, anchor: nil) }
            Button(store.help("Zoom Out", .zoomOut)) { zoom.step(zoomIn: false, anchor: nil) }
            Button(store.help("Zoom to Fit", .zoomFit)) { zoom.zoomToFit() }
        } label: {
            Text(zoom.displayLabel).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Constant width: the text changes every pinch frame; a changing size would re-lay out
        // the whole Develop column (filmstrip included) per frame.
        .frame(width: 96, alignment: .leading)
        .disabled(disabled)
        .help(store.help("Zoom level (pinch or ⌘-scroll to zoom freely)", [.zoomIn, .zoomOut]))
    }
}

enum ZoomBarLevels {
    static let quick: [ZoomLevel] = [.fit, .fill, .ratio(1)]
    /// Tag of the "Custom" segment (a free zoom level).
    static let customTag = ZoomLevel.ratio(-1)

    /// The extra segment for a level outside Fit / Fill / 1:1 (nil for those).
    static func extraSegment(for level: ZoomLevel) -> (label: String, tag: ZoomLevel)? {
        guard !quick.contains(level) else { return nil }
        if case .ratio(let r) = level, ZoomLevel.steps.contains(where: { abs($0 - r) < 1e-9 }) {
            return (CanvasViewport.label(level), level)
        }
        return ("Custom", customTag)
    }
}
