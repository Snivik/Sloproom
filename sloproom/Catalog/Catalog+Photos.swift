//
//  Catalog+Photos.swift
//  sloproom
//

import Foundation

nonisolated extension Catalog {
    /// Column list matching `Photo.init(row:)`. Always select with the `p.` alias.
    static let photoColumns = """
        p.id, p.path, p.root_id, p.file_name, p.file_size, p.capture_date, p.import_date, \
        p.width, p.height, p.orientation, p.camera_make, p.camera_model, p.lens, p.iso, \
        p.shutter, p.aperture, p.focal_length, p.flag, p.rating, p.edit_settings, \
        p.edit_version, p.sidecar_path, p.lr_image_id
        """

    // MARK: - Insert

    /// Inserts a photo, or returns the id of the existing photo with the same `path`
    /// (existing rows are NOT modified). If `photo.rootID` is nil the covering root is filled in.
    @discardableResult
    func insertPhoto(_ photo: Photo) throws -> Int64 {
        try insertPhotos([photo]).first ?? 0
    }

    /// Batch insert in one transaction. Returns ids in input order (existing ids for duplicates).
    /// Posts `.photosInsertedOrRemoved` once if anything was inserted.
    @discardableResult
    func insertPhotos(_ photos: [Photo]) throws -> [Int64] {
        guard !photos.isEmpty else { return [] }
        var inserted = false
        let ids: [Int64] = try db.transaction {
            let roots = try allRoots()
            return try photos.map { p in
                let rootID = p.rootID ?? Self.coveringRoot(for: p.path, in: roots)?.id
                let changed = try db.run("""
                    INSERT INTO photos(path, root_id, file_name, file_size, capture_date, import_date,
                        width, height, orientation, camera_make, camera_model, lens, iso, shutter,
                        aperture, focal_length, flag, rating, edit_settings, edit_version, sidecar_path, lr_image_id)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(path) DO NOTHING
                    """, [
                        p.path, rootID, p.fileName, p.fileSize, p.captureDate, p.importDate,
                        p.width, p.height, p.orientation, p.cameraMake, p.cameraModel, p.lens, p.iso, p.shutter,
                        p.aperture, p.focalLength, p.flag.rawValue, p.rating, p.editSettingsJSON, p.editVersion,
                        p.sidecarPath, p.lrImageID,
                    ])
                if changed > 0 {
                    inserted = true
                    return db.lastInsertRowID
                }
                return try db.scalarInt("SELECT id FROM photos WHERE path = ?", [p.path]) ?? 0
            }
        }
        if inserted { postChange(.photosInsertedOrRemoved) }
        return ids
    }

    // MARK: - Read

    func photo(id: Int64) throws -> Photo? {
        try db.queryFirst("SELECT \(Self.photoColumns) FROM photos p WHERE p.id = ?", [id], Photo.init(row:))
    }

    func photos(ids: [Int64]) throws -> [Photo] {
        try db.locked { try ids.compactMap { try photo(id: $0) } }
    }

    /// Id of the photo at `path`, if catalogued.
    func photoID(path: String) throws -> Int64? {
        try db.scalarInt("SELECT id FROM photos WHERE path = ?", [path])
    }

    func photoIDExists(path: String) throws -> Bool {
        try photoID(path: path) != nil
    }

    func totalPhotoCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM photos") ?? 0)
    }

    /// The main photo query used by the library grid.
    func photos(in source: PhotoSource, filter: PhotoFilter = PhotoFilter(), sort: PhotoSort = PhotoSort()) throws -> [Photo] {
        var args: [any SQLBindable] = []
        var sql: String
        var conditions: [String] = []

        switch source {
        case .all:
            sql = "SELECT \(Self.photoColumns), 0 AS fo FROM photos p"
        case .lastImport:
            sql = "SELECT \(Self.photoColumns), 0 AS fo FROM photos p"
            conditions.append("p.import_date = (SELECT MAX(import_date) FROM photos)")
        case .folder(let id, false):
            sql = """
                SELECT \(Self.photoColumns), fp.sort_order AS fo FROM photos p
                JOIN folder_photos fp ON fp.photo_id = p.id
                """
            conditions.append("fp.folder_id = ?")
            args.append(id)
        case .folder(let id, true):
            sql = """
                WITH RECURSIVE sub(id) AS (
                    SELECT ? UNION ALL SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id)
                SELECT \(Self.photoColumns), MIN(fp.sort_order) AS fo FROM photos p
                JOIN folder_photos fp ON fp.photo_id = p.id
                """
            conditions.append("fp.folder_id IN (SELECT id FROM sub)")
            args.append(id)
        }

        switch filter.flag {
        case .all: break
        case .picked: conditions.append("p.flag = 1")
        case .rejected: conditions.append("p.flag = -1")
        case .unflagged: conditions.append("p.flag = 0")
        case .notRejected: conditions.append("p.flag >= 0")
        }
        if filter.minRating > 0 {
            conditions.append("p.rating >= ?")
            args.append(filter.minRating)
        }

        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if case .folder(_, true) = source { sql += " GROUP BY p.id" }

        let dir = sort.ascending ? "ASC" : "DESC"
        switch sort.key {
        case .captureDate:
            sql += " ORDER BY p.capture_date IS NULL, p.capture_date \(dir), p.file_name \(dir), p.id \(dir)"
        case .importDate:
            sql += " ORDER BY p.import_date \(dir), p.file_name \(dir), p.id \(dir)"
        case .fileName:
            sql += " ORDER BY p.file_name COLLATE NOCASE \(dir), p.id \(dir)"
        case .folderOrder:
            sql += " ORDER BY fo \(dir), p.capture_date \(dir), p.id \(dir)"
        }
        return try db.query(sql, args, Photo.init(row:))
    }

    // MARK: - Update

    func setFlag(_ flag: Flag, for photoIDs: some Collection<Int64>) throws {
        try updateEach(photoIDs, "UPDATE photos SET flag = ? WHERE id = ?", flag.rawValue)
    }

    /// Rating 0...5 (clamped).
    func setRating(_ rating: Int, for photoIDs: some Collection<Int64>) throws {
        try updateEach(photoIDs, "UPDATE photos SET rating = ? WHERE id = ?", min(max(rating, 0), 5))
    }

    func setSidecarPath(_ path: String?, for photoID: Int64) throws {
        try db.run("UPDATE photos SET sidecar_path = ? WHERE id = ?", [path, photoID])
        postChange(.photosUpdated([photoID]))
    }

    /// Saves edit settings (nil or untouched `EditSettings()` store NULL; anything else, e.g. a
    /// hidden or not-yet-adjusted mask, is kept) and bumps `edit_version`. Returns the new edit version.
    @discardableResult
    func saveEditSettings(_ settings: EditSettings?, for photoID: Int64) throws -> Int {
        let json: String? = (settings?.isEmpty ?? true) ? nil : settings?.jsonString()
        let version: Int = try db.transaction {
            try db.run("UPDATE photos SET edit_settings = ?, edit_version = edit_version + 1 WHERE id = ?", [json, photoID])
            return Int(try db.scalarInt("SELECT edit_version FROM photos WHERE id = ?", [photoID]) ?? 0)
        }
        postChange(.photosUpdated([photoID]))
        return version
    }

    /// Removes photos from the catalog (and from all folders). NEVER touches files on disk.
    func removePhotos(ids: some Collection<Int64>) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids { try db.run("DELETE FROM photos WHERE id = ?", [id]) }
        }
        postChange(.photosInsertedOrRemoved)
    }

    private func updateEach(_ ids: some Collection<Int64>, _ sql: String, _ value: any SQLBindable) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids { try db.run(sql, [value, id]) }
        }
        postChange(.photosUpdated(Set(ids)))
    }
}

nonisolated extension Photo {
    /// Maps a row selected with `Catalog.photoColumns` (in that order).
    init(row r: SQLRow) {
        self.init(path: r.string(1), fileName: r.stringOrNil(3))
        id = r.int(0)
        rootID = r.intOrNil(2)
        fileSize = r.int(4)
        captureDate = r.date(5)
        importDate = r.date(6) ?? Date(timeIntervalSince1970: 0)
        width = Int(r.int(7))
        height = Int(r.int(8))
        orientation = r.isNull(9) ? 1 : Int(r.int(9))
        cameraMake = r.stringOrNil(10)
        cameraModel = r.stringOrNil(11)
        lens = r.stringOrNil(12)
        iso = r.intOrNil(13).map(Int.init)
        shutter = r.doubleOrNil(14)
        aperture = r.doubleOrNil(15)
        focalLength = r.doubleOrNil(16)
        flag = Flag(rawValue: Int(r.int(17))) ?? .none
        rating = Int(r.int(18))
        editSettingsJSON = r.stringOrNil(19)
        editVersion = Int(r.int(20))
        sidecarPath = r.stringOrNil(21)
        lrImageID = r.intOrNil(22)
    }
}
