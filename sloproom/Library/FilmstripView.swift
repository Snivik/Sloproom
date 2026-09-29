//
//  FilmstripView.swift
//  sloproom
//
//  Horizontal strip of the current photo list (shown under the Develop canvas).
//

import SwiftUI

struct FilmstripView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(model.photos) { photo in
                        ThumbnailView(photo: photo, level: .thumbnail)
                            .frame(width: 96, height: 72)
                            .padding(2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(model.focusedPhotoID == photo.id ? Color.accentColor : .clear, lineWidth: 2)
                            )
                            .opacity(photo.flag == .reject ? 0.45 : 1)
                            .overlay(alignment: .topLeading) {
                                FlagBadge(flag: photo.flag, isHovering: false, size: 16).padding(5)
                            }
                            .id(photo.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = [photo.id]
                                model.focusedPhotoID = photo.id
                            }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 84)
            .background(.bar)
            .onAppear { if let id = model.focusedPhotoID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: model.focusedPhotoID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}
