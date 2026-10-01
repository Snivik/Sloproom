//
//  PhotoActionUI.swift
//  sloproom
//
//  Window-level UI of the photo actions (installed once on the main window with
//  `.photoActionSupport(model:)`): the Bulk Crop / Sync Settings / Choose Settings to Paste
//  sheets, the Reset Edits and Remove from Catalog confirmations, and the bulk progress HUD.
//

import AppKit
import SwiftUI

@Observable
final class PhotoActionUI {
    static let shared = PhotoActionUI()

    enum Sheet: Identifiable {
        case bulkCrop([Int64])
        case syncSettings(source: Int64, targets: [Int64])
        case pasteSettings([Int64])

        var id: String {
            switch self {
            case .bulkCrop: "bulkCrop"
            case .syncSettings: "syncSettings"
            case .pasteSettings: "pasteSettings"
            }
        }
    }

    var sheet: Sheet?
    /// Reset Edits of several photos: waiting for confirmation.
    var pendingReset: [Int64]?
    /// Remove from Catalog…: waiting for confirmation.
    var pendingRemoval: [Int64]?

    func present(_ sheet: Sheet) { self.sheet = sheet }
}

extension View {
    /// Sheets, confirmations and the progress HUD of the photo actions (main window).
    func photoActionSupport(model: AppModel) -> some View {
        modifier(PhotoActionSupport(model: model))
    }
}

private struct PhotoActionSupport: ViewModifier {
    let model: AppModel
    @Bindable private var ui = PhotoActionUI.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $ui.sheet) { sheet in
                switch sheet {
                case .bulkCrop(let ids):
                    BulkCropSheet(model: model, ids: ids)
                case .syncSettings(let source, let targets):
                    SettingsSectionsSheet(model: model, kind: .sync(source: source), targets: targets)
                case .pasteSettings(let ids):
                    SettingsSectionsSheet(model: model, kind: .paste, targets: ids)
                }
            }
            .confirmationDialog(resetTitle, isPresented: Binding(
                get: { ui.pendingReset != nil },
                set: { if !$0 { ui.pendingReset = nil } }
            ), presenting: ui.pendingReset) { ids in
                Button("Reset \(PhotoActionSpec.photos(ids.count))", role: .destructive) { PhotoActions.resetEdits(ids, model: model) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Every adjustment, crop and mask is removed. You can undo this with Edit > Undo.")
            }
            .confirmationDialog(removalTitle, isPresented: Binding(
                get: { ui.pendingRemoval != nil },
                set: { if !$0 { ui.pendingRemoval = nil } }
            ), presenting: ui.pendingRemoval) { ids in
                Button("Remove from Catalog", role: .destructive) { FolderActions.removeFromCatalog(ids, model: model) }
                Button("Cancel", role: .cancel) {}
            } message: { ids in
                let copies = (try? model.catalog.cascadedVirtualCopyCount(removing: ids)) ?? 0
                Text(copies > 0 ? "Virtual copies are removed with their original. The files on disk are not deleted."
                                : "The files on disk are not deleted.")
            }
            .overlay(alignment: .bottom) { BulkProgressHUD().padding(.bottom, 120) }
    }

    private var resetTitle: String {
        "Reset the edits of \(PhotoActionSpec.photos(ui.pendingReset?.count ?? 0).lowercased())?"
    }

    private var removalTitle: String {
        VirtualCopyActions.removalTitle(ui.pendingRemoval ?? [], model: model)
    }
}

/// "Bulk Crop  120 of 400" with a bar, while a bulk operation on more than 20 photos runs.
private struct BulkProgressHUD: View {
    private var progress: BulkProgress { .shared }

    var body: some View {
        if progress.isActive {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 160)
                Text("\(progress.title)  \(progress.done) of \(progress.total)")
                    .font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .help("Applying to \(progress.total) photos; thumbnails update as their previews regenerate")
            .transition(.opacity)
        }
    }
}
