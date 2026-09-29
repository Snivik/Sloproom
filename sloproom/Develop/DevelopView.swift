//
//  DevelopView.swift
//  sloproom
//

import SwiftUI

struct DevelopView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.developSession {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    DevelopCanvasView(session: session)
                        .id(session.photo.id)
                    Divider()
                    FilmstripView()
                }
                Divider()
                DevelopInspectorView(session: session)
                    .frame(width: 300)
            }
        } else {
            ContentUnavailableView("No Photo Selected", systemImage: "camera.aperture",
                                   description: Text("Select a photo in the Library, then press D."))
        }
    }
}
