//
//  FolderDragPayload.swift
//  sloproom
//
//  In-app drag & drop model (UI-free, tested by Tools/folders_check.swift).
//
//  Drags carry a plain-text payload ("sloproom-drag:photos:1,2,3" / "sloproom-drag:folder:7")
//  in an NSItemProvider. Plain text needs no exported UTType (the app uses a generated
//  Info.plist); drops decode and validate the string, so foreign text is ignored.
//

import Foundation
import CoreGraphics

nonisolated enum SloproomDragPayload: Hashable, Sendable {
    /// Photo ids in grid order (the whole selection when a selected photo is dragged).
    case photos([Int64])
    case folder(Int64)

    static let prefix = "sloproom-drag:"

    var string: String {
        switch self {
        case .photos(let ids): Self.prefix + "photos:" + ids.map(String.init).joined(separator: ",")
        case .folder(let id): Self.prefix + "folder:\(id)"
        }
    }

    init?(string: String) {
        guard string.hasPrefix(Self.prefix) else { return nil }
        let body = string.dropFirst(Self.prefix.count)
        if body.hasPrefix("photos:") {
            let ids = body.dropFirst("photos:".count).split(separator: ",").compactMap { Int64($0) }
            guard !ids.isEmpty else { return nil }
            self = .photos(ids)
        } else if body.hasPrefix("folder:"), let id = Int64(body.dropFirst("folder:".count)) {
            self = .folder(id)
        } else {
            return nil
        }
    }
}

/// Where a dragged folder lands relative to the row under the pointer.
nonisolated enum FolderDropZone: Sendable {
    case before, into, after

    /// Top quarter = before, bottom quarter = after, middle = into.
    init(y: CGFloat, height: CGFloat) {
        let h = max(height, 1)
        if y < h * 0.25 { self = .before } else if y > h * 0.75 { self = .after } else { self = .into }
    }
}

nonisolated enum FolderDropPlanner {
    /// Arguments for `Catalog.moveFolder(id:toParent:index:)` (index among the new siblings,
    /// not counting the moved folder; nil = append).
    struct Destination: Hashable, Sendable {
        var parentID: Int64?
        var index: Int?
    }

    /// Where `moving` goes when dropped on `target` in `zone`; nil when the drop is invalid
    /// (into itself / a descendant) or would change nothing.
    static func destination(moving id: Int64, onto target: Int64, zone: FolderDropZone, folders: [Folder]) -> Destination? {
        guard let moving = folders.first(where: { $0.id == id }),
              let targetFolder = folders.first(where: { $0.id == target }) else { return nil }
        if FolderTree.subtreeIDs(of: id, in: folders).contains(target) { return nil }

        if zone == .into {
            return moving.parentID == target ? nil : Destination(parentID: target, index: nil)
        }
        let parent = targetFolder.parentID
        let siblings = sortedChildren(of: parent, in: folders)
        let others = siblings.filter { $0.id != id }
        guard let targetIndex = others.firstIndex(where: { $0.id == target }) else { return nil }
        let index = zone == .before ? targetIndex : targetIndex + 1
        if moving.parentID == parent, siblings.firstIndex(where: { $0.id == id }) == index { return nil }
        return Destination(parentID: parent, index: index)
    }

    /// Destination for a drop on the "Folders" section (top level, appended); nil if already
    /// the last top-level folder.
    static func topLevelDestination(moving id: Int64, folders: [Folder]) -> Destination? {
        guard let moving = folders.first(where: { $0.id == id }) else { return nil }
        if moving.parentID == nil, sortedChildren(of: nil, in: folders).last?.id == id { return nil }
        return Destination(parentID: nil, index: nil)
    }

    /// Children in display order — same order as `FolderTree.build` / `Catalog.moveFolder`.
    static func sortedChildren(of parent: Int64?, in folders: [Folder]) -> [Folder] {
        folders.filter { $0.parentID == parent }
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }
}
