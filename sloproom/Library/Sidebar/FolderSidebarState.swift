//
//  FolderSidebarState.swift
//  sloproom
//
//  UI state of the Folders sidebar that menus/commands also touch (so it lives outside the
//  view): persisted expansion, the folder being renamed inline, pending delete confirmation.
//  Plus `SidebarCounts`: flag counts and subtree totals refreshed off-main on catalog changes.
//

import Foundation
import Observation
import SwiftUI

struct PendingFolderDeletion: Identifiable {
    let folder: Folder
    let subfolderCount: Int
    var id: Int64 { folder.id }

    var title: String {
        subfolderCount == 0
            ? "Delete folder “\(folder.name)”?"
            : "Delete folder “\(folder.name)” and its \(subfolderCount) subfolder\(subfolderCount == 1 ? "" : "s")?"
    }
}

@Observable
final class FolderSidebarState {
    static let shared = FolderSidebarState()
    private static let expandedKey = "sidebar.expandedFolderIDs"

    /// Expanded folder ids (persisted in UserDefaults).
    private(set) var expanded: Set<Int64>
    /// Folder whose name is being edited inline in the sidebar.
    var renamingFolderID: Int64?
    var pendingDeletion: PendingFolderDeletion?

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.expandedKey) as? [Int] ?? []
        expanded = Set(stored.map(Int64.init))
    }

    func isExpanded(_ id: Int64) -> Bool { expanded.contains(id) }

    func setExpanded(_ id: Int64, _ isExpanded: Bool) {
        guard expanded.contains(id) != isExpanded else { return }
        if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
        UserDefaults.standard.set(expanded.sorted().map(Int.init), forKey: Self.expandedKey)
    }

    func expansionBinding(_ id: Int64) -> Binding<Bool> {
        Binding { self.isExpanded(id) } set: { self.setExpanded(id, $0) }
    }

    /// Expands `id` and all its ancestors so it (and its children) are visible.
    func reveal(_ id: Int64, in folders: [Folder]) {
        for f in FolderTree.path(to: id, in: folders) { setExpanded(f.id, true) }
    }

    /// Drops ids of folders that no longer exist.
    func prune(to folders: [Folder]) {
        let ids = Set(folders.map(\.id))
        for id in expanded where !ids.contains(id) { setExpanded(id, false) }
        if let r = renamingFolderID, !ids.contains(r) { renamingFolderID = nil }
    }
}

/// Picked / rejected counts and per-folder totals incl. subfolders. Queries run off-main,
/// coalesced (at most one in flight, one queued) so bursts of edits stay cheap.
@Observable
final class SidebarCounts {
    private(set) var flags = FlagCounts()
    /// Distinct photos per folder including descendants (absent = 0).
    private(set) var folderTotals: [Int64: Int] = [:]

    @ObservationIgnored private var catalog: Catalog?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var needsRefresh = false

    func start(catalog: Catalog) {
        guard self.catalog == nil else { return }
        self.catalog = catalog
        observer = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: catalog, queue: .main) { [weak self] note in
            switch Catalog.change(from: note) {
            case .roots?, .cropPresets?, nil: return
            default: MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        guard let catalog else { return }
        if isRefreshing { needsRefresh = true; return }
        isRefreshing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let flags = (try? catalog.flagCounts()) ?? FlagCounts()
            let totals = (try? catalog.folderTotalPhotoCounts()) ?? [:]
            await self?.finishRefresh(flags: flags, totals: totals)
        }
    }

    private func finishRefresh(flags: FlagCounts, totals: [Int64: Int]) {
        if self.flags != flags { self.flags = flags }
        if folderTotals != totals { folderTotals = totals }
        isRefreshing = false
        if needsRefresh { needsRefresh = false; refresh() }
    }
}
