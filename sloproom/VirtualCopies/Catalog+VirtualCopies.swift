//
//  Catalog+VirtualCopies.swift
//  sloproom
//
//  Virtual copies: extra `photos` rows pointing at the SAME file as their master (same path,
//  root, metadata, sidecar, import date), with their own edit settings / edit version, flag,
//  rating, folder memberships and previews. `master_id` always points at a master (a copy of a
//  copy is another copy of the same master); `copy_name` is "Copy N" (N = 1 + the highest number
//  among the master's existing "Copy N" copies, so a number is never reused while that copy
//  exists) or a user-chosen name. The file on disk is never touched or duplicated.
//  Removing a master removes its copies (ON DELETE CASCADE); removing a copy removes only it.
//  Engine file (harness: Tools/vcopies_check.swift).
//

import Foundation

nonisolated enum VirtualCopyError: Error, CustomStringConvertible, LocalizedError {
    case notAVirtualCopy
    case emptyName

    var description: String {
        switch self {
        case .notAVirtualCopy: "Only virtual copies can be renamed."
        case .emptyName: "The name of a virtual copy can't be empty."
        }
    }
    var errorDescription: String? { description }
}

/// One copy created by `createVirtualCopies`.
nonisolated struct CreatedVirtualCopy: Sendable, Hashable {
    /// The new copy.
    var id: Int64
    /// The photo it was made from (a master or another copy; its edits were copied).
    var sourceID: Int64
    /// The copy's master.
    var masterID: Int64
    var copyName: String
}

nonisolated extension Catalog {
    /// Creates one virtual copy of each photo in `photoIDs` (unknown ids are skipped), in one
    /// transaction. Each copy starts with its source's edit settings (and edit version, so the
    /// source's previews can seed the copy's), flag and rating — unless `initialSettings`
    /// returns settings for that source (seam for e.g. per-folder default crops) — and is
    /// appended to `folderID` if given. Posts `.photosInsertedOrRemoved` (+ `.folderMembership`).
    @discardableResult
    func createVirtualCopies(of photoIDs: [Int64], inFolder folderID: Int64? = nil,
                             initialSettings: ((Photo) -> EditSettings?)? = nil) throws -> [CreatedVirtualCopy] {
        guard !photoIDs.isEmpty else { return [] }
        let created: [CreatedVirtualCopy] = try db.transaction {
            var out: [CreatedVirtualCopy] = []
            var nextOrder = try folderID.map {
                try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM folder_photos WHERE folder_id = ?", [$0]) ?? 0
            }
            for sourceID in photoIDs {
                guard let source = try photo(id: sourceID) else { continue }
                let masterID = source.masterID ?? source.id
                let name = "Copy \(try nextCopyNumber(masterID: masterID))"
                var json = source.editSettingsJSON
                var version = source.editVersion
                if let settings = initialSettings?(source) {
                    json = settings.isEmpty ? nil : settings.jsonString()
                    version += 1   // different settings than the source: its previews don't apply
                }
                try db.run("""
                    INSERT INTO photos(path, root_id, file_name, file_size, capture_date, import_date,
                        width, height, orientation, camera_make, camera_model, lens, iso, shutter,
                        aperture, focal_length, flag, rating, edit_settings, edit_version, sidecar_path,
                        lr_image_id, master_id, copy_name)
                    SELECT path, root_id, file_name, file_size, capture_date, import_date,
                        width, height, orientation, camera_make, camera_model, lens, iso, shutter,
                        aperture, focal_length, flag, rating, ?, ?, sidecar_path,
                        NULL, ?, ?
                    FROM photos WHERE id = ?
                    """, [json, version, masterID, name, source.id])
                let id = db.lastInsertRowID
                if let folderID, let order = nextOrder {
                    try db.run("INSERT OR IGNORE INTO folder_photos(folder_id, photo_id, sort_order) VALUES (?,?,?)", [folderID, id, order])
                    nextOrder = order + 1
                }
                out.append(CreatedVirtualCopy(id: id, sourceID: source.id, masterID: masterID, copyName: name))
            }
            return out
        }
        if !created.isEmpty {
            postChange(.photosInsertedOrRemoved)
            if let folderID { postChange(.folderMembership([folderID])) }
        }
        return created
    }

    /// 1 + the highest N of the master's copies named "Copy N" (1 when it has none).
    func nextCopyNumber(masterID: Int64) throws -> Int {
        let names = try db.query("SELECT copy_name FROM photos WHERE master_id = ?", [masterID]) { $0.stringOrNil(0) }
        let numbers = names.compactMap { name -> Int? in
            guard let name, name.hasPrefix("Copy ") else { return nil }
            return Int(name.dropFirst(5))
        }
        return (numbers.max() ?? 0) + 1
    }

    /// Renames a virtual copy (e.g. "Story"); shown in titles and used for export names.
    func renameVirtualCopy(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VirtualCopyError.emptyName }
        guard try db.run("UPDATE photos SET copy_name = ? WHERE id = ? AND master_id IS NOT NULL", [trimmed, id]) > 0 else {
            throw VirtualCopyError.notAVirtualCopy
        }
        postChange(.photosUpdated([id]))
    }

    /// Ids of the virtual copies of these masters (copies in `masterIDs` are ignored), by id.
    func virtualCopyIDs(ofMasters masterIDs: some Collection<Int64>) throws -> [Int64] {
        guard !masterIDs.isEmpty else { return [] }
        return try db.locked {
            try masterIDs.flatMap { try db.query("SELECT id FROM photos WHERE master_id = ? ORDER BY id", [$0]) { $0.int(0) } }
        }
    }

    /// Number of virtual copies that removing `ids` from the catalog removes too (copies of the
    /// masters in `ids` that aren't in `ids` themselves).
    func cascadedVirtualCopyCount(removing ids: some Collection<Int64>) throws -> Int {
        let set = Set(ids)
        return try virtualCopyIDs(ofMasters: set).filter { !set.contains($0) }.count
    }

    /// `ids` plus the virtual copies of the masters among them (what `removePhotos(ids:)` deletes).
    func idsIncludingVirtualCopies(_ ids: some Collection<Int64>) throws -> [Int64] {
        let set = Set(ids)
        return Array(ids) + (try virtualCopyIDs(ofMasters: set).filter { !set.contains($0) })
    }

    /// Total number of virtual copies in the catalog.
    func virtualCopyCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM photos WHERE master_id IS NOT NULL") ?? 0)
    }
}
