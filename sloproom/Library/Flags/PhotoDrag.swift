//
//  PhotoDrag.swift
//  sloproom
//
//  Photo drag source shared by the Library grid and the Develop filmstrip: the payload is
//  `SloproomDragPayload.photos` (dropped on sidebar folders by `FolderRowDropDelegate`,
//  ⌘ = move out of the shown folder, ⌥ = virtual copies: `PhotoDropVerb`). Dragging a selected
//  photo drags the whole selection. Dragged out of the app (Finder…) the item is the file URL of
//  the original under the pointer.
//

import SwiftUI

extension View {
    /// `PhotoDrag.operations` on macOS 26+; older systems keep SwiftUI's copy-only drag source
    /// (⌘-drag then can't move, plain and ⌥ drags still work).
    func photoDragOperations() -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(dragConfiguration(PhotoDrag.operations))
        }
        return AnyView(self)
    }
}

enum PhotoDrag {
    /// Operations the grid / filmstrip drag source offers (`.dragConfiguration`). SwiftUI's
    /// `onDrag` alone offers only copy, which AppKit's modifier handling can mask out (⌘ = move);
    /// the folder drop verbs (PhotoDropVerb) propose alias / move / copy.
    @available(macOS 26.0, *)
    static var operations: DragConfiguration {
        var within = DragConfiguration.OperationsWithinApp(allowCopy: true, allowMove: true)
        within.allowAlias = true
        return DragConfiguration(operationsWithinApp: within, operationsOutsideApp: .init(allowCopy: true))
    }

    /// Ids dragged when the drag starts on `photo`: the whole selection (list order) if `photo`
    /// is selected, else just `photo` — which the grid also selects (`selectUnselected`); the
    /// filmstrip leaves the selection alone so a drag doesn't switch the photo in Develop.
    static func ids(for photo: Photo, model: AppModel, selectUnselected: Bool) -> [Int64] {
        if model.selection.contains(photo.id) { return model.orderedSelection }
        if selectUnselected { model.click(photoID: photo.id, command: false, shift: false) }
        return [photo.id]
    }

    static func provider(for photo: Photo, model: AppModel, selectUnselected: Bool) -> NSItemProvider {
        let ids = ids(for: photo, model: model, selectUnselected: selectUnselected)
        #if DEBUG
        print("PhotoDrag: start \(ids.count) photo(s) from \(photo.fileName)")
        #endif
        let provider = SloproomDrag.provider(.photos(ids))
        // Outside the app (Finder, Mail…): the original file of the photo under the pointer
        // (copy only). In-app drops read the plain-text payload registered first.
        provider.registerObject(photo.url as NSURL, visibility: .all)
        return provider
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
