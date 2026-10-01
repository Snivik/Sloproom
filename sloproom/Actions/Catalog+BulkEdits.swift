//
//  Catalog+BulkEdits.swift
//  sloproom
//
//  Bulk edit engine (UI-free; Tools/actions_check.swift): apply a settings transform to many
//  photos and remember what they had before, so ONE undo step can restore them all.
//
//  - `saveEditSettings(_ edits:)`: many photos in one transaction, ONE `.photosUpdated`
//    notification; every row's `edit_version` is bumped like `saveEditSettings(_:for:)`, so
//    previews regenerate through the usual edit-version invalidation (nothing renders here).
//  - `BulkEdit.apply` reads the photos, transforms, writes in chunks (progress callback) and
//    returns a `BulkEditChange` (before / after per id; nil = no settings, stored as NULL).
//  - `BulkEdit.write` writes a stored side of a change back (undo = `before`, redo = `after`).
//
//  Call off the main thread for many photos.
//

import Foundation

nonisolated struct BulkEditChange: Sendable, Equatable {
    /// Settings before / after per photo id (nil = the photo had no settings = NULL).
    var before: [Int64: EditSettings?] = [:]
    var after: [Int64: EditSettings?] = [:]
    /// Ids in the order they were given (only the photos that changed).
    var ids: [Int64] = []
    /// Ids skipped (unknown size for a crop, or the transform changed nothing).
    var skipped: [Int64] = []

    var isEmpty: Bool { ids.isEmpty }
}

nonisolated extension Catalog {
    /// Saves settings of many photos in one transaction (nil / empty settings → NULL) and posts
    /// one `.photosUpdated`. Returns the new edit versions.
    @discardableResult
    func saveEditSettings(_ edits: [(id: Int64, settings: EditSettings?)]) throws -> [Int64: Int] {
        guard !edits.isEmpty else { return [:] }
        var versions: [Int64: Int] = [:]
        try db.transaction {
            for (id, settings) in edits {
                let json: String? = (settings?.isEmpty ?? true) ? nil : settings?.jsonString()
                try db.run("UPDATE photos SET edit_settings = ?, edit_version = edit_version + 1 WHERE id = ?", [json, id])
                versions[id] = Int(try db.scalarInt("SELECT edit_version FROM photos WHERE id = ?", [id]) ?? 0)
            }
        }
        postChange(.photosUpdated(Set(edits.map(\.id))))
        return versions
    }
}

nonisolated enum BulkEdit {
    /// Rows per transaction (and progress tick).
    static let chunkSize = 200

    /// Applies `transform` to the photos `ids` (list order kept). `transform` gets the photo and
    /// its current settings and returns the new settings, or nil to leave the photo alone.
    /// `current` overrides the catalog's settings for some ids (the photo open in Develop, whose
    /// newest settings may not be saved yet). `progress(done, total)` is called after each chunk.
    static func apply(catalog: Catalog, ids: [Int64], current: [Int64: EditSettings] = [:],
                      transform: (Photo, EditSettings) -> EditSettings?,
                      progress: ((Int, Int) -> Void)? = nil) throws -> BulkEditChange {
        let photos = try catalog.photos(ids: ids)
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var change = BulkEditChange()
        var pending: [(id: Int64, settings: EditSettings?)] = []
        var done = 0
        for id in ids {
            guard let photo = byID[id], change.before[id] == nil else { continue }
            let old = current[id] ?? photo.editSettings
            let oldStored: EditSettings? = current[id].map { $0.isEmpty ? nil : $0 } ?? EditSettings.fromJSON(photo.editSettingsJSON)
            guard let new = transform(photo, old), new != old else { change.skipped.append(id); continue }
            // updateValue: assigning nil through the subscript would REMOVE the key.
            change.before.updateValue(oldStored, forKey: id)
            change.after.updateValue(new.isEmpty ? nil : new, forKey: id)
            change.ids.append(id)
            pending.append((id, new))
            if pending.count >= chunkSize {
                try catalog.saveEditSettings(pending)
                done += pending.count
                pending.removeAll()
                progress?(done, ids.count)
            }
        }
        if !pending.isEmpty { try catalog.saveEditSettings(pending); done += pending.count }
        progress?(ids.count, ids.count)
        return change
    }

    /// Writes one side of a change (undo: `change.before`, redo: `change.after`).
    static func write(_ values: [Int64: EditSettings?], order: [Int64], catalog: Catalog,
                      progress: ((Int, Int) -> Void)? = nil) throws {
        var pending: [(id: Int64, settings: EditSettings?)] = []
        var done = 0
        for id in order {
            guard let value = values[id] else { continue }
            pending.append((id, value))
            if pending.count >= chunkSize {
                try catalog.saveEditSettings(pending)
                done += pending.count
                pending.removeAll()
                progress?(done, order.count)
            }
        }
        if !pending.isEmpty { try catalog.saveEditSettings(pending) }
        progress?(order.count, order.count)
    }
}
