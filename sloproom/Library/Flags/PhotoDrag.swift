//
//  PhotoDrag.swift
//  sloproom
//
//  Photo drag source shared by the Library grid and the Develop filmstrip: the payload is
//  `SloproomDragPayload.photos` (dropped on sidebar folders by `FolderRowDropDelegate`,
//  ⌘ = move out of the shown folder, ⌥ = virtual copies: `PhotoDropVerb`). Dragging a selected
//  photo drags the whole selection.
//

import SwiftUI

enum PhotoDrag {
    /// Ids dragged when the drag starts on `photo`: the whole selection (list order) if `photo`
    /// is selected, else just `photo` — which the grid also selects (`selectUnselected`); the
    /// filmstrip leaves the selection alone so a drag doesn't switch the photo in Develop.
    static func ids(for photo: Photo, model: AppModel, selectUnselected: Bool) -> [Int64] {
        if model.selection.contains(photo.id) { return model.orderedSelection }
        if selectUnselected { model.click(photoID: photo.id, command: false, shift: false) }
        return [photo.id]
    }

    static func provider(for photo: Photo, model: AppModel, selectUnselected: Bool) -> NSItemProvider {
        #if DEBUG
        let ids = ids(for: photo, model: model, selectUnselected: selectUnselected)
        print("PhotoDrag: start \(ids.count) photo(s) from \(photo.fileName)")
        return SloproomDrag.provider(.photos(ids))
        #else
        return SloproomDrag.provider(.photos(ids(for: photo, model: model, selectUnselected: selectUnselected)))
        #endif
    }

    /// Small thumbnail with the number of dragged photos.
    static func preview(_ photo: Photo, model: AppModel) -> some View {
        let count = model.selection.contains(photo.id) ? model.selection.count : 1
        return ZStack(alignment: .topTrailing) {
            if let image = PreviewService.shared.cachedImage(for: photo, level: .thumbnail) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            if count > 1 {
                Text(count.formatted())
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: 96, height: 96)
    }
}
