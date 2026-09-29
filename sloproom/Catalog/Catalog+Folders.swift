//
//  Catalog+Folders.swift
//  sloproom
//
//  Virtual folders (collections). Arbitrarily nested; a folder holds subfolders and photos;
//  a photo can be in many folders. Deleting a folder deletes its subfolders and memberships,
//  never photos.
//

import Foundation

nonisolated enum CatalogError: Error, CustomStringConvertible {
    case folderCycle
    case notFound

    var description: String {
        switch self {
        case .folderCycle: "A folder cannot be moved into itself or one of its subfolders."
        case .notFound: "Item not found in catalog."
        }
    }
}

nonisolated extension Catalog {
    private static let folderColumns = "id, parent_id, name, sort_order, created_at, lr_collection_id"

    private static func folder(row r: SQLRow) -> Folder {
        Folder(id: r.int(0), parentID: r.intOrNil(1), name: r.string(2), sortOrder: Int(r.int(3)),
               createdAt: r.date(4) ?? Date(), lrCollectionID: r.intOrNil(5))
    }

    /// All folders, flat, ordered by (parent, sort_order, name). Build a tree with `FolderTree`.
    func allFolders() throws -> [Folder] {
        try db.query("SELECT \(Self.folderColumns) FROM folders ORDER BY parent_id, sort_order, name COLLATE NOCASE", [], Self.folder(row:))
    }

    func folder(id: Int64) throws -> Folder? {
        try db.queryFirst("SELECT \(Self.folderColumns) FROM folders WHERE id = ?", [id], Self.folder(row:))
    }

    /// Creates a folder as the last child of `parentID` (nil = top level). Returns its id.
    @discardableResult
    func createFolder(name: String, parentID: Int64? = nil, lrCollectionID: Int64? = nil) throws -> Int64 {
        let id: Int64 = try db.transaction {
            let next = try nextSiblingOrder(parentID: parentID)
            try db.run("INSERT INTO folders(parent_id, name, sort_order, created_at, lr_collection_id) VALUES (?,?,?,?,?)",
                       [parentID, name, next, Date(), lrCollectionID])
            return db.lastInsertRowID
        }
        postChange(.folders)
        return id
    }

    func renameFolder(id: Int64, to name: String) throws {
        try db.run("UPDATE folders SET name = ? WHERE id = ?", [name, id])
        postChange(.folders)
    }

    /// Moves `id` under `parentID` (nil = top level) at position `index` among its new siblings
    /// (clamped; nil = append). Throws `CatalogError.folderCycle` when moving into itself/descendant.
    func moveFolder(id: Int64, toParent parentID: Int64?, index: Int? = nil) throws {
        try db.transaction {
            // Cycle check: walk up from the new parent.
            var cursor = parentID
            while let c = cursor {
                if c == id { throw CatalogError.folderCycle }
                cursor = try db.queryFirst("SELECT parent_id FROM folders WHERE id = ?", [c]) { $0.intOrNil(0) } ?? nil
            }
            var siblings = try db.query(
                "SELECT id FROM folders WHERE parent_id IS ? AND id != ? ORDER BY sort_order, name COLLATE NOCASE",
                [parentID, id]) { $0.int(0) }
            let at = min(max(index ?? siblings.count, 0), siblings.count)
            siblings.insert(id, at: at)
            try db.run("UPDATE folders SET parent_id = ? WHERE id = ?", [parentID, id])
            for (order, fid) in siblings.enumerated() {
                try db.run("UPDATE folders SET sort_order = ? WHERE id = ?", [order, fid])
            }
        }
        postChange(.folders)
    }

    /// Deletes the folder and (by cascade) all its subfolders and memberships. Photos stay.
    func deleteFolder(id: Int64) throws {
        try db.run("DELETE FROM folders WHERE id = ?", [id])
        postChange(.folders)
    }

    /// Ids of `id` and all its descendants.
    func folderSubtreeIDs(_ id: Int64) throws -> [Int64] {
        try db.query("""
            WITH RECURSIVE sub(id) AS (
                SELECT ? UNION ALL SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id)
            SELECT id FROM sub
            """, [id]) { $0.int(0) }
    }

    // MARK: - Membership

    /// Adds photos (appended at the end; already-present photos are left in place).
    func addPhotos(_ photoIDs: some Collection<Int64>, toFolder folderID: Int64) throws {
        guard !photoIDs.isEmpty else { return }
        try db.transaction {
            var next = Int(try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM folder_photos WHERE folder_id = ?", [folderID]) ?? 0)
            for pid in photoIDs {
                if try db.run("INSERT OR IGNORE INTO folder_photos(folder_id, photo_id, sort_order) VALUES (?,?,?)", [folderID, pid, next]) > 0 {
                    next += 1
                }
            }
        }
        postChange(.folderMembership([folderID]))
    }

    func removePhotos(_ photoIDs: some Collection<Int64>, fromFolder folderID: Int64) throws {
        guard !photoIDs.isEmpty else { return }
        try db.transaction {
            for pid in photoIDs {
                try db.run("DELETE FROM folder_photos WHERE folder_id = ? AND photo_id = ?", [folderID, pid])
            }
        }
        postChange(.folderMembership([folderID]))
    }

    func movePhotos(_ photoIDs: some Collection<Int64>, from source: Int64, to destination: Int64) throws {
        guard source != destination else { return }
        try db.transaction {
            try addPhotos(photoIDs, toFolder: destination)
            try removePhotos(photoIDs, fromFolder: source)
        }
    }

    /// Direct photo count of one folder, optionally including all descendants (distinct photos).
    func photoCount(folderID: Int64, includeSubfolders: Bool = false) throws -> Int {
        if !includeSubfolders {
            return Int(try db.scalarInt("SELECT COUNT(*) FROM folder_photos WHERE folder_id = ?", [folderID]) ?? 0)
        }
        return Int(try db.scalarInt("""
            WITH RECURSIVE sub(id) AS (
                SELECT ? UNION ALL SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id)
            SELECT COUNT(DISTINCT photo_id) FROM folder_photos WHERE folder_id IN (SELECT id FROM sub)
            """, [folderID]) ?? 0)
    }

    /// Direct photo counts for every folder that has photos (folders with 0 are absent).
    func folderPhotoCounts() throws -> [Int64: Int] {
        let rows = try db.query("SELECT folder_id, COUNT(*) FROM folder_photos GROUP BY folder_id") { ($0.int(0), Int($0.int(1))) }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// Folders that directly contain `photoID`.
    func folderIDs(containing photoID: Int64) throws -> [Int64] {
        try db.query("SELECT folder_id FROM folder_photos WHERE photo_id = ?", [photoID]) { $0.int(0) }
    }

    private func nextSiblingOrder(parentID: Int64?) throws -> Int {
        Int(try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM folders WHERE parent_id IS ?", [parentID]) ?? 0)
    }
}
