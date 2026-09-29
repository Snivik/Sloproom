//
//  FilmstripView.swift
//  sloproom
//
//  Horizontal strip of the current photo list (shown under the Develop canvas).
//  Same selection model as the grid (`AppModel.click`): click selects one, ⌘-click toggles,
//  ⇧-click extends a range. The focused photo (the one open in Develop) gets a bright frame,
//  other selected photos a lighter one; P / U / X / ratings act on the whole selection
//  (`AppModel.actionTargetIDs`). Photos drag onto sidebar folders like grid cells (a selected
//  photo drags the whole selection, ⌥ = move). Arrow keys: DevelopCanvasView (← / →).
//
//  Clicks are an `onTapGesture` next to `.onDrag`: unlike a List row (where `.onDrag`
//  swallowed clicks in the sidebar), a plain view keeps both.
//

import AppKit
import SwiftUI

struct FilmstripView: View {
    @Environment(AppModel.self) private var model

    static let thumbnailSize = CGSize(width: 96, height: 68)
    static let height: CGFloat = 100

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(model.photos) { photo in
                        FilmstripCell(photo: photo,
                                      isSelected: model.selection.contains(photo.id),
                                      isFocused: model.focusedPhotoID == photo.id)
                            .id(photo.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                model.click(photoID: photo.id, command: flags.contains(.command), shift: flags.contains(.shift))
                            }
                            .onDrag { PhotoDrag.provider(for: photo, model: model, selectUnselected: false) } preview: { PhotoDrag.preview(photo, model: model) }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: Self.height)
            .background(.bar)
            .onAppear { if let id = model.focusedPhotoID { proxy.scrollTo(id, anchor: .center) } }
            // Minimal scroll (no anchor): clicking a visible photo never moves the strip under the
            // pointer, arrow keys scroll only at the edges, and a photo that left the list hands
            // focus to its neighbour without a jump.
            .onChange(of: model.focusedPhotoID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
    }
}

private struct FilmstripCell: View {
    let photo: Photo
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 2) {
            ThumbnailView(photo: photo, level: .thumbnail)
                .rejectedVeil(photo.flag == .reject)
                .frame(width: FilmstripView.thumbnailSize.width, height: FilmstripView.thumbnailSize.height)
                .overlay(alignment: .topLeading) {
                    FlagBadge(flag: photo.flag, isHovering: false, size: 16).padding(2)
                }
            Text(photo.fileName)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isFocused ? .primary : .secondary)
                .frame(width: FilmstripView.thumbnailSize.width)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isFocused ? Color.accentColor.opacity(0.38) : isSelected ? Color.accentColor.opacity(0.17) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isFocused ? Color.accentColor : isSelected ? Color.accentColor.opacity(0.45) : .clear,
                              lineWidth: isFocused ? 2 : 1)
        )
        .help(photo.fileName)
    }
}
