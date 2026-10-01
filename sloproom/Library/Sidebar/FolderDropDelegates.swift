//
//  FolderDropDelegates.swift
//  sloproom
//
//  Drag sources and drop targets for photos and folders.
//
//  - Drag start (`SloproomDrag.provider`) records the payload in `SloproomDrag.current`, so drop
//    targets can pick the right zone while hovering (item providers can't be read synchronously).
//  - `performDrop` decodes the provider's text, so a stale `current` or foreign text never acts.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SloproomDrag {
    /// Payload of the drag in progress (last drag started in this app).
    static var current: SloproomDragPayload?

    static func provider(_ payload: SloproomDragPayload) -> NSItemProvider {
        current = payload
        return NSItemProvider(object: payload.string as NSString)
    }

    /// Decodes the dropped payload and delivers it on the main actor (ignores foreign drops).
    static func load(_ info: DropInfo, _ completion: @escaping @MainActor @Sendable (SloproomDragPayload) -> Void) {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        _ = provider.loadObject(ofClass: String.self) { string, _ in
            guard let string, let payload = SloproomDragPayload(string: string) else { return }
            Task { @MainActor in completion(payload) }
        }
    }

    static var isOptionDown: Bool { NSEvent.modifierFlags.contains(.option) }
}

/// Drop on a folder row: photos are added (⌘ = moved out of the shown folder, ⌥ = virtual
/// copies; `PhotoDropVerb`); folders are nested (middle of the row) or placed before / after it
/// (top / bottom quarter).
struct FolderRowDropDelegate: DropDelegate {
    let folderID: Int64
    let rowHeight: CGFloat
    let model: AppModel
    @Binding var zone: FolderDropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && SloproomDrag.current != nil
    }

    func dropEntered(info: DropInfo) { zone = proposedZone(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let z = proposedZone(info)
        if z != zone { zone = z }
        guard z != nil else { PhotoDropFeedback.shared.update(nil, .add); return DropProposal(operation: .forbidden) }
        if case .photos? = SloproomDrag.current {
            let verb = PhotoDropVerb.current(onto: folderID, model: model)
            PhotoDropFeedback.shared.update(folderID, verb)
            return DropProposal(operation: verb.operation)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
        if PhotoDropFeedback.shared.folderID == folderID { PhotoDropFeedback.shared.update(nil, .add) }
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = proposedZone(info)
        zone = nil
        PhotoDropFeedback.shared.update(nil, .add)
        guard let z else { return false }
        let verb = PhotoDropVerb.current(onto: folderID, model: model)
        let folderID = folderID, model = model
        SloproomDrag.load(info) { payload in
            switch payload {
            case .photos(let ids):
                verb.perform(ids, onto: folderID, model: model)
            case .folder(let id):
                if let dest = FolderDropPlanner.destination(moving: id, onto: folderID, zone: z, folders: model.folders) {
                    FolderActions.move(id, to: dest, model: model)
                }
            }
        }
        return true
    }

    private func proposedZone(_ info: DropInfo) -> FolderDropZone? {
        switch SloproomDrag.current {
        case .photos?:
            return .into
        case .folder(let id)?:
            let z = FolderDropZone(y: info.location.y, height: rowHeight)
            return FolderDropPlanner.destination(moving: id, onto: folderID, zone: z, folders: model.folders) == nil ? nil : z
        case nil:
            return nil
        }
    }
}

/// Drop a folder on the "Folders" section header: move it to the top level (appended).
struct TopLevelFolderDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var isTargeted: Bool

    private var draggedFolder: Int64? {
        if case .folder(let id)? = SloproomDrag.current { return id }
        return nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && draggedFolder != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = draggedFolder.flatMap { FolderDropPlanner.topLevelDestination(moving: $0, folders: model.folders) } != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isTargeted ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        let ok = isTargeted
        isTargeted = false
        guard ok else { return false }
        let model = model
        SloproomDrag.load(info) { payload in
            guard case .folder(let id) = payload,
                  let dest = FolderDropPlanner.topLevelDestination(moving: id, folders: model.folders) else { return }
            FolderActions.move(id, to: dest, model: model)
        }
        return true
    }
}
