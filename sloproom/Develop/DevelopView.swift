//
//  DevelopView.swift
//  sloproom
//
//  Canvas + view bar (zoom, panels, full screen) + filmstrip, inspector on the right.
//  Tab hides the side panels, ⇧Tab everything but the canvas (DevelopPanels). The inspector
//  stays in the hierarchy while hidden (zero width): its panels install keyboard shortcuts
//  (R = crop) and load state on appear.
//

import SwiftUI

struct DevelopView: View {
    @Environment(AppModel.self) private var model
    private var panels: DevelopPanels { DevelopPanels.shared }

    var body: some View {
        if let session = model.developSession {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    DevelopCanvasView(session: session)
                        .id(session.photo.id)
                    if !panels.filmstripHidden {
                        Divider()
                        DevelopViewBar(session: session)
                        Divider()
                        FilmstripView()
                    }
                }
                if !panels.inspectorHidden { Divider() }
                DevelopInspectorView(session: session)
                    .frame(width: 300)
                    .frame(width: panels.inspectorHidden ? 0 : 300, alignment: .leading)
                    .clipped()
                    .opacity(panels.inspectorHidden ? 0 : 1)
                    .allowsHitTesting(!panels.inspectorHidden)
                    .accessibilityHidden(panels.inspectorHidden)
            }
            .developPanelShortcuts()
            .onDisappear { ZoomController.develop.purge() }
        } else {
            ContentUnavailableView("No Photo Selected", systemImage: "camera.aperture",
                                   description: Text("Select a photo in the Library, then press D."))
        }
    }
}
