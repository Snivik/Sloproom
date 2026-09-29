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

    /// Fit / Fill / 1:1 (+ the current level when it isn't one of them).
    private var zoomSegmentHelp: [String] {
        var tips = [store.help("Fit: whole photo", .zoomToggle), "Fill: photo fills the canvas",
                    store.help("1:1: one image pixel per screen pixel", .zoomToggle)]
        if !ZoomBarLevels.quick.contains(zoom.level) { tips.append("Current zoom level") }
        return tips
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker("Zoom", selection: Binding(
                get: { quickLevel },
                set: { zoom.setLevel($0, anchor: nil, remember: true) }
            )) {
                Text("Fit").tag(ZoomLevel.fit)
                Text("Fill").tag(ZoomLevel.fill)
                Text("1:1").tag(ZoomLevel.ratio(1))
                if !ZoomBarLevels.quick.contains(zoom.level) {
                    Text(CanvasViewport.label(zoom.level)).tag(zoom.level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(session.activeTool == .crop)
            .segmentHelp(zoomSegmentHelp)

            Menu {
                ForEach(ZoomLevel.steps, id: \.self) { r in
                    Button(CanvasViewport.label(.ratio(r))) { zoom.setLevel(.ratio(r), anchor: nil, remember: true) }
                }
                Divider()
                Button(store.help("Zoom In", .zoomIn)) { zoom.step(zoomIn: true, anchor: nil) }
                Button(store.help("Zoom Out", .zoomOut)) { zoom.step(zoomIn: false, anchor: nil) }
            } label: {
                Text(zoom.displayLabel).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.activeTool == .crop)
            .help(store.help("Zoom level (pinch or ⌘-scroll to zoom)", [.zoomIn, .zoomOut]))

            Spacer()

            Button { panels.sidebarHidden.toggle() } label: { Image(systemName: "sidebar.left") }
                .iconHelp(panels.sidebarHidden ? "Show Folders" : "Hide Folders")
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

    /// Selected segment (a level outside Fit / Fill / 1:1 shows as an extra segment).
    private var quickLevel: ZoomLevel { zoom.level }
}

enum ZoomBarLevels {
    static let quick: [ZoomLevel] = [.fit, .fill, .ratio(1)]
}
