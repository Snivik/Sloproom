//
//  PhotoActions.swift
//  sloproom
//
//  The photo actions registry, app half: each `PhotoActionSpec` (PhotoActionSpec.swift: title,
//  symbol, tooltip, arity, modes, shortcut) gets its model-dependent enablement and its `perform`.
//  Every surface — grid and filmstrip context menus, the menu bar's Photo menu, the Develop
//  toolbar's actions menu — is built from this (`PhotoActionMenus.swift`), and targets are always
//  resolved by `PhotoActions.targets(model:clicked:)` (= `PhotoActionTargets.resolve`).
//
//  Behaviour of the ported actions is unchanged (they call the same FolderActions /
//  VirtualCopyActions / FlagActions / ExportController code as before). Bulk edits (Paste / Sync
//  Settings, Bulk Crop, Reset Edits) go through `BulkEditor` (off-main for many photos, progress,
//  ONE undo step).
//

import AppKit
import SwiftUI

enum PhotoActions {
    // MARK: Targets

    static func mode(_ model: AppModel) -> PhotoActionMode { model.mode == .develop ? .develop : .library }

    /// THE target resolution (see `PhotoActionTargets.resolve`). `clicked` = the cell a context
    /// menu was opened on.
    static func targets(model: AppModel, clicked: Int64? = nil) -> PhotoActionTargets {
        PhotoActionTargets.resolve(mode: mode(model), orderedSelection: model.orderedSelection,
                                   focusedID: model.focusedPhotoID, clickedID: clicked)
    }

    // MARK: Availability

    /// Hidden actions are left out of menus entirely (as before: Move to Folder / Remove from This
    /// Folder only while a folder is shown, Rename only for virtual copies, folder submenus only
    /// when there are folders).
    static func isVisible(_ spec: PhotoActionSpec, _ targets: PhotoActionTargets, model: AppModel) -> Bool {
        guard spec.modes.contains(targets.mode.modes) else { return false }
        switch spec.id {
        case .moveToFolder, .removeFromFolder: return model.shownFolderID != nil
        case .addToFolder, .copyToFolder: return !model.folderTree.isEmpty
        case .renameVirtualCopy: return targets.ids.contains { photo($0, model)?.isVirtualCopy == true }
        default: return true
        }
    }

    static func availability(_ spec: PhotoActionSpec, _ targets: PhotoActionTargets, model: AppModel) -> PhotoActionAvailability {
        guard isVisible(spec, targets, model: model) else { return .hidden }
        let base = spec.availability(count: targets.count, mode: targets.mode)
        guard base == .enabled else { return base }
        switch spec.id {
        case .pasteSettings, .pasteSettingsChoose:
            if DevelopClipboard.copied == nil { return .disabled("Copy Settings from a photo first") }
        case .renameVirtualCopy:
            if photo(targets.ids[0], model)?.isVirtualCopy != true { return .disabled("Only virtual copies can be renamed") }
        default: break
        }
        return .enabled
    }

    /// Tooltip: why it's disabled, else the help text with the current shortcut.
    static func tooltip(_ spec: PhotoActionSpec, _ availability: PhotoActionAvailability) -> String {
        if case .disabled(let reason) = availability { return reason }
        return ShortcutStore.shared.help(spec.help, spec.shortcut)
    }

    static func photo(_ id: Int64, _ model: AppModel) -> Photo? {
        model.photo(id: id) ?? (try? model.catalog.photo(id: id))
    }

    // MARK: Perform

    /// Menu bar / shortcut entry: resolves the targets now and performs if allowed (else beeps).
    static func performFromMenu(_ id: PhotoActionID, model: AppModel) {
        let spec = PhotoActionSpec.spec(id)
        let targets = targets(model: model)
        guard availability(spec, targets, model: model).isEnabled else { NSSound.beep(); return }
        perform(id, targets, model: model, fromMenuBar: true)
    }

    /// Performs a non-folder action on `targets` (callers checked availability).
    static func perform(_ id: PhotoActionID, _ targets: PhotoActionTargets, model: AppModel, fromMenuBar: Bool = false) {
        let ids = targets.ids
        guard !ids.isEmpty else { return }
        switch id {
        case .openInDevelop:
            model.openInDevelop(ids[0])
        case .showInFinder:
            showInFinder(ids[0], model: model)
        case .createVirtualCopy:
            if fromMenuBar { VirtualCopyActions.createFromMenu(model: model) } else { VirtualCopyActions.create(ids, model: model) }
        case .renameVirtualCopy:
            VirtualCopyActions.requestRename(ids, model: model)
        case .pick: flag(.pick, targets, model: model, fromMenuBar: fromMenuBar)
        case .unflag: flag(.none, targets, model: model, fromMenuBar: fromMenuBar)
        case .reject: flag(.reject, targets, model: model, fromMenuBar: fromMenuBar)
        case .copySettings:
            copySettings(ids[0], model: model)
        case .pasteSettings:
            pasteSettings(ids, model: model)
        case .pasteSettingsChoose:
            PhotoActionUI.shared.present(.pasteSettings(ids))
        case .syncSettings:
            guard let source = targets.primaryID else { return }
            PhotoActionUI.shared.present(.syncSettings(source: source, targets: ids.filter { $0 != source }))
        case .bulkCrop:
            PhotoActionUI.shared.present(.bulkCrop(ids))
        case .resetEdits:
            if ids.count > 1 { PhotoActionUI.shared.pendingReset = ids } else { resetEdits(ids, model: model) }
        case .newFolderWithPhotos:
            FolderActions.newFolder(parentID: nil, photoIDs: ids, model: model)
        case .newFolderWithVirtualCopies:
            VirtualCopyActions.newFolder(with: ids, model: model)
        case .removeFromFolder:
            FolderActions.removeFromShownFolder(ids, model: model)
        case .exportJPEG:
            ExportController.shared.present(ids: ids, model: model)
        case .removeFromCatalog:
            PhotoActionUI.shared.pendingRemoval = ids
        case .addToFolder, .moveToFolder, .copyToFolder:
            break   // folder submenus: performFolder
        }
    }

    /// Add to / Move to / Copy to Folder ▸ <folder>.
    static func performFolder(_ id: PhotoActionID, _ targets: PhotoActionTargets, folderID: Int64, model: AppModel) {
        let ids = targets.ids
        guard !ids.isEmpty else { return }
        switch id {
        case .addToFolder: FolderActions.addPhotos(ids, to: folderID, move: false, model: model)
        case .moveToFolder: FolderActions.addPhotos(ids, to: folderID, move: true, model: model)
        case .copyToFolder: VirtualCopyActions.copy(ids, to: folderID, model: model)
        default: break
        }
    }

    // MARK: Implementations

    /// Pick / Unflag / Reject. Menu bar / keys: FlagActions (auto advance), as before. Context
    /// menus: a Library cell outside the selection is selected first (as the grid always did),
    /// then the targets are flagged without advancing.
    private static func flag(_ flag: Flag, _ targets: PhotoActionTargets, model: AppModel, fromMenuBar: Bool) {
        if fromMenuBar {
            FlagActions.setFlag(flag, model: model)
        } else if targets.clickedOutsideSelection, targets.mode == .library, let id = targets.ids.first {
            model.click(photoID: id, command: false, shift: false)
            model.setFlag(flag)
        } else {
            do { try model.catalog.setFlag(flag, for: targets.ids) } catch { model.report(error) }
        }
    }

    /// Copy Settings: the photo open in Develop (live settings) or the catalog's.
    static func copySettings(_ id: Int64, model: AppModel) {
        if let session = model.developSession, session.photo.id == id {
            session.copySettings()
        } else if let photo = photo(id, model) {
            DevelopClipboard.copy(photo.editSettings, from: photo)
        }
    }

    /// Paste Settings (the remembered sections). Only the photo open in Develop → one Develop
    /// undo step, as before; otherwise a bulk edit (one undo step for all).
    static func pasteSettings(_ ids: [Int64], sections: Set<EditSection>? = nil, model: AppModel) {
        guard let copied = DevelopClipboard.copied else { NSSound.beep(); return }
        let sections = sections ?? DevelopClipboard.pasteSections
        BulkEditor.apply("Paste Settings", ids: ids, model: model) { _, s in s.replacing(sections, from: copied) }
    }

    /// Sync Settings: `sections` of `source` (live settings if it is open in Develop) onto `targets`.
    static func syncSettings(from source: Int64, to targets: [Int64], sections: Set<EditSection>, model: AppModel) {
        let settings: EditSettings
        if let session = model.developSession, session.photo.id == source { settings = session.settings }
        else if let p = photo(source, model) { settings = p.editSettings }
        else { return }
        BulkEditor.apply("Sync Settings", ids: targets, model: model) { _, s in s.replacing(sections, from: settings) }
    }

    static func resetEdits(_ ids: [Int64], model: AppModel) {
        BulkEditor.apply("Reset Edits", ids: ids, model: model) { _, _ in EditSettings() }
    }

    static func bulkCrop(_ ids: [Int64], options: BulkCropOptions, model: AppModel) {
        BulkEditor.apply("Bulk Crop", ids: ids, model: model) { photo, s in
            BulkCrop.apply(options, to: s, sourceSize: photo.orientedSize)
        }
    }

    /// Reveals the original in the Finder (a virtual copy: its master's file).
    static func showInFinder(_ id: Int64, model: AppModel) {
        guard let photo = photo(id, model) else { return }
        let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: model.catalog)
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.errorMessage = "The original of \(photo.displayTitle) is offline or missing:\n\(photo.path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
