//
//  VirtualCopyActions.swift
//  sloproom
//
//  Virtual copies in the UI (engine: Catalog+VirtualCopies.swift):
//  - Create Virtual Copy (Photo menu, ⌘' by default = registry action `createVirtualCopy`, grid +
//    filmstrip context menus — menus come from the photo actions registry, Actions/): one copy per target, added to the folder being shown (like
//    Lightroom), then selected; in Develop the (first) copy opens so it can be re-cropped at once.
//  - Copy to Folder ▸ / New Folder with Virtual Copies: copies created INSIDE the chosen / new
//    folder (the owner's "Instagram Stories" workflow); the grid keeps its selection.
//  - Rename Virtual Copy… (alert with a text field), the copy badge, the Develop info row, the
//    "remove from catalog" wording, and the three folder verbs' help texts.
//

import AppKit
import SwiftUI

enum VirtualCopyActions {
    // The three folder verbs, worded the same everywhere (menus, drag & drop feedback).
    static let addHelp = "Add to Folder: the same photo, edits shared (⌥-drag: copy, ⌘-drag: move)"
    static let moveHelp = "Move to Folder: take the photo out of this folder and put it in another"
    static let copyHelp = "Copy to Folder: an independent virtual copy with its own crop and edits (⌥-drag onto a folder)"
    static let newFolderWithCopiesHelp = "Creates a folder holding independent virtual copies (own crop and edits) of the photos"

    /// Photo > Create Virtual Copy (⌘'): copies of the action targets.
    static func createFromMenu(model: AppModel) {
        guard !FullScreenPreview.shared.isShowing else { return }
        create(model.actionTargetIDs, model: model)
    }

    /// Copies of `ids` in the shown folder (if any); the copies become the selection, the first
    /// one the focused photo (in Develop: the photo being edited).
    static func create(_ ids: [Int64], model: AppModel) {
        guard let created = make(ids, folderID: model.shownFolderID, model: model), !created.isEmpty else { return }
        model.reloadPhotos()   // show them now; the catalog notification reloads again in place
        let shown = created.map(\.id).filter { model.photo(id: $0) != nil }
        guard let first = shown.first else { return }
        model.click(photoID: first, command: false, shift: false)
        model.selection = Set(shown)
    }

    /// Copy to Folder ▸: copies of `ids` inside `folderID`. Selection unchanged.
    static func copy(_ ids: [Int64], to folderID: Int64, model: AppModel) {
        make(ids, folderID: folderID, model: model)
    }

    /// New Folder with Virtual Copies: "Untitled Folder" (unique) at the top level holding
    /// copies of `ids`; starts its inline rename like New Folder with Photos.
    static func newFolder(with ids: [Int64], model: AppModel) {
        guard !ids.isEmpty, let folderID = FolderActions.newFolder(parentID: nil, model: model) else { return }
        make(ids, folderID: folderID, model: model)
    }

    /// Flushes pending Develop edits (the copy starts with the CURRENT settings), creates the
    /// copies and seeds their previews from their sources' (no re-render).
    @discardableResult
    private static func make(_ ids: [Int64], folderID: Int64?, model: AppModel) -> [CreatedVirtualCopy]? {
        guard !ids.isEmpty else { return nil }
        if let session = model.developSession, ids.contains(session.photo.id) {
            session.saveNow()
            DevelopSession.flushPendingSaves()
        }
        do {
            let t0 = Date()
            let created = try model.catalog.createVirtualCopies(of: ids, inFolder: folderID)
            VirtualCopyPreviews.seed(created, catalog: model.catalog)
            #if DEBUG
            print("VirtualCopies: created \(created.count) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms "
                  + "(\(created.map { "\($0.id)←\($0.sourceID) \($0.copyName)" }.joined(separator: ", ")))")
            #endif
            return created
        } catch {
            model.report(error)
            return nil
        }
    }

    // MARK: Rename

    /// Photo > Rename Virtual Copy… / context menu: asks for a name (single virtual copy).
    static func requestRename(_ ids: [Int64], model: AppModel) {
        guard ids.count == 1, let photo = model.photo(id: ids[0]) ?? (try? model.catalog.photo(id: ids[0])),
              photo.isVirtualCopy else { NSSound.beep(); return }
        VirtualCopyRenameState.shared.begin(photo)
    }

    static func rename(_ id: Int64, to name: String, model: AppModel) {
        do { try model.catalog.renameVirtualCopy(id: id, to: name) } catch { model.report(error) }
    }

    // MARK: Removal wording

    /// "Remove this photo from the catalog?" / "… and its 2 virtual copies …".
    static func removalTitle(_ ids: [Int64], model: AppModel) -> String {
        let copies = (try? model.catalog.cascadedVirtualCopyCount(removing: ids)) ?? 0
        let what = ids.count == 1 ? "this photo" : "\(ids.count) photos"
        guard copies > 0 else { return "Remove \(what) from the catalog?" }
        let theirs = ids.count == 1 ? "its" : "their"
        return "Remove \(what) and \(theirs) \(copies) virtual cop\(copies == 1 ? "y" : "ies") from the catalog?"
    }

    /// Removes from the catalog (masters take their copies along) and deletes the previews of
    /// everything removed. Files on disk are never touched.
    static func removeFromCatalog(_ ids: [Int64], model: AppModel) {
        let all = (try? model.catalog.idsIncludingVirtualCopies(ids)) ?? ids
        do { try model.catalog.removePhotos(ids: ids) } catch { model.report(error); return }
        // After the grid has reloaded without them (cells still on screen would regenerate a
        // discarded preview), so a little later and off the main thread.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { PreviewService.shared.discard(photoIDs: all) }
    }
}

// MARK: - Menus
// Context menus (grid, filmstrip, Develop actions menu) and the Photo menu are built from the
// photo actions registry (Actions/PhotoActionSpec.swift + PhotoActions.swift), which calls the
// functions above.

// MARK: - Rename alert

@Observable
final class VirtualCopyRenameState {
    static let shared = VirtualCopyRenameState()
    var photo: Photo?
    var draft = ""

    func begin(_ photo: Photo) {
        draft = photo.copyName ?? ""
        self.photo = photo
    }
}

extension View {
    /// The Rename Virtual Copy alert (installed once on the main window).
    func virtualCopySupport(model: AppModel) -> some View {
        modifier(VirtualCopyRenameAlert(model: model))
    }
}

private struct VirtualCopyRenameAlert: ViewModifier {
    let model: AppModel
    @Bindable private var state = VirtualCopyRenameState.shared

    func body(content: Content) -> some View {
        content.alert("Rename Virtual Copy", isPresented: Binding(
            get: { state.photo != nil },
            set: { if !$0 { state.photo = nil } }
        ), presenting: state.photo) { photo in
            TextField("Name", text: $state.draft)
            Button("Rename") { VirtualCopyActions.rename(photo.id, to: state.draft, model: model) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { photo in
            Text("Virtual copy of \(photo.fileName). The name is shown in titles and used for exported file names.")
        }
    }
}

// MARK: - Badge / info

/// Monochrome "virtual copy" badge for grid / filmstrip cells, styled like `FlagBadge`.
struct VirtualCopyBadge: View {
    let photo: Photo
    var size: CGFloat = 22

    var body: some View {
        if let text = photo.virtualCopyDescription {
            Image(systemName: "square.on.square")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.42), in: Circle())
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                .help(text)
                .accessibilityLabel(text)
        }
    }
}

/// Develop inspector line for a virtual copy: what it is + Rename….
struct VirtualCopyInfoRow: View {
    @Environment(AppModel.self) private var model
    let photoID: Int64

    var body: some View {
        if let photo = model.photo(id: photoID), let text = photo.virtualCopyDescription {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Rename…") { VirtualCopyActions.requestRename([photo.id], model: model) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Rename this virtual copy (e.g. “Story”)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .help("This is an independent virtual copy: its crop and edits don't change the original")
        }
    }
}
