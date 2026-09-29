//
//  DevelopSession+Masks.swift
//  sloproom
//
//  Mask helpers for the panel and overlay. All edits go through `settings`, so they are
//  saved, rendered and undoable like any other change.
//

import Foundation

extension DevelopSession {
    var selectedMask: Mask? { selectedMaskID.flatMap(mask(id:)) }

    func mask(id: UUID) -> Mask? { settings.masks.first { $0.id == id } }

    /// Mutates one mask in place (one settings change).
    func updateMask(_ id: UUID, _ change: (inout Mask) -> Void) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        var m = settings.masks[i]
        change(&m)
        if m != settings.masks[i] { settings.masks[i] = m }
    }

    /// Appends a new mask, selects it and activates the mask tool. Returns its id.
    @discardableResult
    func addMask(_ shape: MaskShape) -> UUID {
        let mask = Mask(name: MaskEditing.nextName(for: shape.kind, existing: settings.masks), shape: shape)
        settings.masks.append(mask)
        selectMask(mask.id)
        return mask.id
    }

    func deleteMask(_ id: UUID) {
        commitUndoGroup()
        settings.masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = nil }
        commitUndoGroup()
    }

    func duplicateMask(_ id: UUID) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        commitUndoGroup()
        var copy = settings.masks[i]
        copy.id = UUID()
        copy.name = copy.name + " copy"
        settings.masks.insert(copy, at: i + 1)
        commitUndoGroup()
        selectMask(copy.id)
    }

    func selectMask(_ id: UUID?) {
        selectedMaskID = id
        if id != nil {
            MaskToolState.shared.pendingKind = nil
            activeTool = .mask
        }
    }

    /// "Create New Mask": the next drag on the canvas creates a mask of `kind`.
    func beginCreatingMask(_ kind: MaskKind) {
        commitUndoGroup()
        selectedMaskID = nil
        MaskToolState.shared.pendingKind = kind
        activeTool = .mask
    }

    /// Leaves the mask tool (Esc / Done).
    func finishMasking() {
        MaskToolState.shared.pendingKind = nil
        commitUndoGroup()
        activeTool = .none
    }
}
