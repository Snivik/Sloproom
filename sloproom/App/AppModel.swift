//
//  AppModel.swift
//  sloproom
//
//  Global UI state (MainActor). One instance per app, injected with `.environment(model)`.
//  Reloads itself when the catalog posts `Catalog.didChange`.
//

import Foundation
import Observation
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case library, develop
    var id: String { rawValue }
    var title: String { self == .library ? "Library" : "Develop" }
}

enum SheetKind: String, Identifiable {
    case importPhotos, importLightroom, previewSettings
    var id: String { rawValue }
}

@Observable
final class AppModel {
    /// Replaced only by `replaceCatalog(with:)` (File > Import Catalog…).
    private(set) var catalog: Catalog

    // MARK: Folders
    private(set) var folders: [Folder] = []
    private(set) var folderTree: [FolderNode] = []
    /// Direct photo counts per folder id (absent = 0).
    private(set) var folderCounts: [Int64: Int] = [:]
    private(set) var totalPhotoCount = 0

    // MARK: Current photo list
    var selectedSource: PhotoSource = .all { didSet { if selectedSource != oldValue { reloadPhotos() } } }
    /// When a folder is selected, also show photos of its subfolders. On by default (Lightroom
    /// collection sets have no photos of their own); remembered across launches.
    var includeSubfolders = UserDefaults.standard.object(forKey: "library.includeSubfolders") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeSubfolders, forKey: "library.includeSubfolders")
            if case .folder(let id, _) = selectedSource { selectedSource = .folder(id: id, includeSubfolders: includeSubfolders) }
        }
    }
    var filter = PhotoFilter() { didSet { if filter != oldValue { reloadPhotos() } } }
    var sort = PhotoSort() { didSet { if sort != oldValue { reloadPhotos() } } }
    private(set) var photos: [Photo] = []
    private var photoIndex: [Int64: Int] = [:]

    // MARK: Selection
    var selection: Set<Int64> = []
    /// The "current" photo: keyboard focus in the grid, the photo shown in Develop.
    var focusedPhotoID: Int64? {
        didSet {
            guard focusedPhotoID != oldValue else { return }
            if mode == .develop { openDevelopSession() }
        }
    }
    /// Anchor for shift-click range selection.
    private var selectionAnchorID: Int64?

    // MARK: Mode / sheets
    var mode: AppMode = .library {
        didSet {
            guard mode != oldValue else { return }
            if mode == .develop { openDevelopSession() } else { closeDevelopSession() }
        }
    }
    var presentedSheet: SheetKind?
    private(set) var developSession: DevelopSession?
    /// Last user-visible error (shown as an alert by MainWindowView).
    var errorMessage: String?

    private var pendingReloadPhotos = false
    private var pendingReloadFolders = false
    private var observer: NSObjectProtocol?

    init(catalog: Catalog) {
        self.catalog = catalog
        PreviewService.shared.configure(catalog: catalog)
        observeCatalog()
        reloadFolders()
        reloadPhotos()
    }

    private func observeCatalog() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: catalog, queue: .main) { [weak self] note in
            guard let change = Catalog.change(from: note) else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        }
    }

    // MARK: - Catalog lifecycle (CatalogTransfer: Import Catalog)

    /// Leaves Develop (its pending edits are queued for saving), closes sheets and empties the
    /// photo list so the grid stops loading previews of the catalog about to be replaced.
    func prepareForCatalogReplacement() {
        mode = .library
        presentedSheet = nil
        selection = []
        selectionAnchorID = nil
        focusedPhotoID = nil
        photos = []
        photoIndex = [:]
    }

    /// Switches to `newCatalog` (already open): previews service, observers, folders, photos;
    /// selection reset, source = All Photographs. The old catalog must be closed by the caller.
    func replaceCatalog(with newCatalog: Catalog) {
        prepareForCatalogReplacement()
        pendingReloadPhotos = false
        pendingReloadFolders = false
        catalog = newCatalog
        PreviewService.shared.configure(catalog: newCatalog)
        observeCatalog()
        selectedSource = .all
        filter = PhotoFilter()
        reloadFolders()
        reloadPhotos()
    }

    /// Opens the default catalog; aborts with a clear message if impossible.
    static func makeDefault() -> AppModel {
        do {
            return AppModel(catalog: try Catalog.openDefault())
        } catch {
            fatalError("Cannot open catalog at \(Catalog.defaultDirectory.path): \(error)")
        }
    }

    // MARK: - Derived

    var focusedPhoto: Photo? { focusedPhotoID.flatMap(photo(id:)) }
    func photo(id: Int64) -> Photo? { photoIndex[id].map { photos[$0] } }
    func index(of id: Int64) -> Int? { photoIndex[id] }

    /// Photos that commands (flag, rating, add to folder…) act on:
    /// in Library the selection, or the focused photo; in Develop every photo selected in the
    /// filmstrip when the current photo is part of a multi-selection, else the current photo.
    var actionTargetIDs: [Int64] {
        if mode == .develop {
            guard let focused = focusedPhotoID else { return [] }
            guard selection.count > 1, selection.contains(focused) else { return [focused] }
            return orderedSelection
        }
        if !selection.isEmpty { return orderedSelection }
        return focusedPhotoID.map { [$0] } ?? []
    }

    /// The selection in list order.
    var orderedSelection: [Int64] { photos.map(\.id).filter(selection.contains) }

    // MARK: - Loading

    /// Reloads the list for a new source / filter / sort.
    func reloadPhotos() { reloadPhotos(inPlace: false) }

    /// `inPlace`: the same list changed under the user (flag, removal, membership…). A focused
    /// photo that dropped out (e.g. unpicked while the Picked filter is on) hands focus to the
    /// photo that took its place — the next remaining one, or the previous one if it was last —
    /// so focus never falls back to the start / end of the list.
    private func reloadPhotos(inPlace: Bool) {
        let oldPhotos = photos
        do {
            photos = try catalog.photos(in: selectedSource, filter: filter, sort: sort)
            totalPhotoCount = try catalog.totalPhotoCount()
        } catch {
            report(error)
            photos = []
        }
        photoIndex = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
        let focusWasSelected = focusedPhotoID.map(selection.contains) ?? false
        selection = selection.filter { photoIndex[$0] != nil }
        if let f = focusedPhotoID, photoIndex[f] == nil {
            if inPlace, let replacement = replacement(for: f, in: oldPhotos) {
                if selection.isEmpty && focusWasSelected { selection = [replacement] }
                if selectionAnchorID.map({ photoIndex[$0] == nil }) ?? true { selectionAnchorID = replacement }
                focusedPhotoID = replacement
            } else if mode == .library {
                focusedPhotoID = nil
            }
        }
        if let a = selectionAnchorID, photoIndex[a] == nil { selectionAnchorID = nil }
    }

    /// The photo that took `id`'s place after a reload: the first photo after it in `oldPhotos`
    /// that is still listed, else the nearest one before it.
    private func replacement(for id: Int64, in oldPhotos: [Photo]) -> Int64? {
        guard let i = oldPhotos.firstIndex(where: { $0.id == id }) else { return nil }
        if let next = oldPhotos[(i + 1)...].first(where: { photoIndex[$0.id] != nil }) { return next.id }
        if let previous = oldPhotos[..<i].last(where: { photoIndex[$0.id] != nil }) { return previous.id }
        return photos.isEmpty ? nil : photos[min(i, photos.count - 1)].id
    }

    func reloadFolders() {
        do {
            folders = try catalog.allFolders()
            folderCounts = try catalog.folderPhotoCounts()
        } catch { report(error) }
        folderTree = FolderTree.build(folders)
        if case .folder(let id, _) = selectedSource, !folders.contains(where: { $0.id == id }) {
            selectedSource = .all
        }
    }

    /// Coalesces bursts of catalog notifications into one reload per run-loop turn.
    private func handle(_ change: CatalogChange) {
        switch change {
        case .photosUpdated, .photosInsertedOrRemoved:
            pendingReloadPhotos = true
            if change == .photosInsertedOrRemoved { pendingReloadFolders = true }
        case .folders, .folderMembership:
            pendingReloadFolders = true
            pendingReloadPhotos = true
        case .roots:
            // Photos' root_id may have changed (a granted parent folder replaces inner roots).
            pendingReloadPhotos = true
        case .cropPresets:
            return
        }
        DispatchQueue.main.async { [weak self] in self?.flushPendingReloads() }
    }

    private func flushPendingReloads() {
        if pendingReloadFolders { pendingReloadFolders = false; reloadFolders() }
        if pendingReloadPhotos { pendingReloadPhotos = false; reloadPhotos(inPlace: true) }
    }

    func report(_ error: Error) {
        errorMessage = String(describing: error)
    }

    // MARK: - Selection

    /// Grid / filmstrip click. ⌘ toggles, ⇧ extends a range from the anchor, plain click selects
    /// one. The clicked photo becomes the focused (current) photo, except when ⌘-click deselects
    /// it: focus then stays on / moves to a photo that is still selected (Lightroom behaviour).
    func click(photoID: Int64, command: Bool, shift: Bool) {
        if shift, let anchor = selectionAnchorID ?? focusedPhotoID, let a = photoIndex[anchor], let b = photoIndex[photoID] {
            let range = photos[min(a, b)...max(a, b)].map(\.id)
            selection = command ? selection.union(range) : Set(range)
            selectionAnchorID = anchor
        } else if command {
            selectionAnchorID = photoID
            if selection.contains(photoID) {
                selection.remove(photoID)
                if let f = focusedPhotoID, f != photoID, selection.contains(f) { return }
                if let nearest = nearestSelected(to: photoID) { focusedPhotoID = nearest; return }
            } else {
                selection.insert(photoID)
            }
        } else {
            selection = [photoID]
            selectionAnchorID = photoID
        }
        focusedPhotoID = photoID
    }

    /// The selected photo closest to `id` in list order (ties: the later one).
    private func nearestSelected(to id: Int64) -> Int64? {
        guard !selection.isEmpty, let i = photoIndex[id] else { return nil }
        return selection.compactMap { s in photoIndex[s].map { (s, abs($0 - i), $0 < i) } }
            .min { ($0.1, $0.2 ? 1 : 0) < ($1.1, $1.2 ? 1 : 0) }?.0
    }

    func selectAll() {
        selection = Set(photos.map(\.id))
    }

    /// Moves focus by `delta` photos (arrow keys). Selection follows unless `extend`.
    func moveFocus(by delta: Int, extend: Bool = false) {
        guard !photos.isEmpty else { return }
        let current = focusedPhotoID.flatMap { photoIndex[$0] } ?? (delta > 0 ? -1 : photos.count)
        let next = min(max(current + delta, 0), photos.count - 1)
        let id = photos[next].id
        if extend { selection.insert(id) } else { selection = [id]; selectionAnchorID = id }
        focusedPhotoID = id
    }

    // MARK: - Actions

    func setFlag(_ flag: Flag) {
        let ids = actionTargetIDs
        guard !ids.isEmpty else { return }
        do { try catalog.setFlag(flag, for: ids) } catch { report(error) }
    }

    func setRating(_ rating: Int) {
        let ids = actionTargetIDs
        guard !ids.isEmpty else { return }
        do { try catalog.setRating(rating, for: ids) } catch { report(error) }
    }

    @discardableResult
    func createFolder(name: String, parentID: Int64?) -> Int64? {
        do { return try catalog.createFolder(name: name, parentID: parentID) } catch { report(error); return nil }
    }

    func openInDevelop(_ photoID: Int64) {
        if !selection.contains(photoID) { selection = [photoID] }
        focusedPhotoID = photoID
        mode = .develop
        openDevelopSession()
    }

    // MARK: - Develop session

    private func openDevelopSession() {
        if focusedPhotoID == nil, let first = selection.first ?? photos.first?.id { focusedPhotoID = first }
        guard let id = focusedPhotoID else { closeDevelopSession(); return }
        if developSession?.photo.id == id { return }
        closeDevelopSession()
        guard let photo = photo(id: id) ?? (try? catalog.photo(id: id)) else { return }
        developSession = DevelopSession(photo: photo, catalog: catalog)
    }

    private func closeDevelopSession() {
        developSession?.close()
        developSession = nil
    }
}
