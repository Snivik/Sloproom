//
//  Catalog+FolderManagement.swift
//  sloproom
//
//  Catalog API used by the sidebar / grid folder management: grouped counts (one query each,
//  cheap enough for 100 folders x 22k photos), multi-folder photo moves and unique names.
//  UI-free so the CLI harness (Tools/folders_check.swift) can compile it.
//

import Foundation

/// Photo counts per flag over the whole catalog.
nonisolated struct FlagCounts: Hashable, Sendable {
    var picked = 0
    var rejected = 0
    var unflagged = 0
    var total: Int { picked + rejected + unflagged }
}

nonisolated extension Catalog {
    /// Counts per flag in one grouped query.
    func flagCounts() throws -> FlagCounts {
        var counts = FlagCounts()
        let rows = try db.query("SELECT flag, COUNT(*) FROM photos GROUP BY flag") { ($0.int(0), Int($0.int(1))) }
        for (flag, n) in rows {
            switch flag {
            case 1: counts.picked += n
            case -1: counts.rejected += n
            default: counts.unflagged += n
            }
        }
        return counts
    }

    /// Distinct photo count of every folder INCLUDING all its descendants, in one query
    /// (folders whose subtree has no photos are absent). Direct counts: `folderPhotoCounts()`.
    func folderTotalPhotoCounts() throws -> [Int64: Int] {
        let rows = try db.query("""
            WITH RECURSIVE anc(folder_id, ancestor_id) AS (
                SELECT id, id FROM folders
                UNION
                SELECT anc.folder_id, f.parent_id FROM anc JOIN folders f ON f.id = anc.ancestor_id
                WHERE f.parent_id IS NOT NULL)
            SELECT anc.ancestor_id, COUNT(DISTINCT fp.photo_id)
            FROM folder_photos fp JOIN anc ON anc.folder_id = fp.folder_id
            GROUP BY anc.ancestor_id
            """) { ($0.int(0), Int($0.int(1))) }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// Removes photos from each of `folderIDs` in one transaction / one notification.
    func removePhotos(_ photoIDs: some Collection<Int64>, fromFolders folderIDs: some Collection<Int64>) throws {
        guard !photoIDs.isEmpty, !folderIDs.isEmpty else { return }
        try db.transaction {
            for fid in folderIDs {
                for pid in photoIDs {
                    try db.run("DELETE FROM folder_photos WHERE folder_id = ? AND photo_id = ?", [fid, pid])
                }
            }
        }
        postChange(.folderMembership(Set(folderIDs)))
    }

    /// Adds photos to `destination` and removes them from every folder in `sources`
    /// (except `destination` itself). One transaction, one notification.
    func movePhotos(_ photoIDs: some Collection<Int64>, fromFolders sources: some Collection<Int64>, to destination: Int64) throws {
        guard !photoIDs.isEmpty else { return }
        let sources = Set(sources).subtracting([destination])
        try db.transaction {
            var next = Int(try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM folder_photos WHERE folder_id = ?", [destination]) ?? 0)
            for pid in photoIDs {
                if try db.run("INSERT OR IGNORE INTO folder_photos(folder_id, photo_id, sort_order) VALUES (?,?,?)", [destination, pid, next]) > 0 {
                    next += 1
                }
            }
            for fid in sources {
                for pid in photoIDs {
                    try db.run("DELETE FROM folder_photos WHERE folder_id = ? AND photo_id = ?", [fid, pid])
                }
            }
        }
        postChange(.folderMembership(sources.union([destination])))
    }

    /// `base`, or "base 2", "base 3"… — the first name not used by a sibling under `parentID`
    /// (case-insensitive).
    func uniqueFolderName(_ base: String, parentID: Int64?) throws -> String {
        let taken = Set(try db.query("SELECT name FROM folders WHERE parent_id IS ?", [parentID]) { $0.string(0).lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
