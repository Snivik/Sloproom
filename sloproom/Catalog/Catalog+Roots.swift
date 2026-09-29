//
//  Catalog+Roots.swift
//  sloproom
//
//  Roots (security-scoped disk locations) and crop presets.
//

import Foundation

nonisolated extension Catalog {
    // MARK: - Roots

    private static func root(row r: SQLRow) -> Root {
        Root(id: r.int(0), path: r.string(1), bookmark: r.data(2), displayName: r.stringOrNil(3))
    }

    /// THE path normalization for root ↔ photo matching (roots are stored normalized; photo paths
    /// are normalized when matched): standardized (`.`/`..`/`~`), no trailing slash, and the
    /// `/private` prefix of `/private/var|tmp|etc` removed deterministically (`standardizingPath`
    /// only strips it when the path exists, which differs between online and offline files).
    static func normalizedPath(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        for top in ["/private/var", "/private/tmp", "/private/etc"] where p == top || p.hasPrefix(top + "/") {
            p.removeFirst("/private".count)
            break
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Normalizes a directory path for storage/matching (same as `normalizedPath`).
    static func normalizedRootPath(_ path: String) -> String { normalizedPath(path) }

    /// True if `path` is `rootPath` or inside it. Both are normalized with `normalizedPath`.
    static func path(_ path: String, isUnderRoot rootPath: String) -> Bool {
        let path = normalizedPath(path), rootPath = normalizedPath(rootPath)
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    /// Inserts or updates the root at `path` and returns its id. Photos under `path` that have no
    /// root yet are attached to it.
    @discardableResult
    func upsertRoot(path: String, bookmark: Data?, displayName: String? = nil) throws -> Int64 {
        let path = Self.normalizedRootPath(path)
        let id: Int64 = try db.transaction {
            try db.run("""
                INSERT INTO roots(path, bookmark, display_name) VALUES (?,?,?)
                ON CONFLICT(path) DO UPDATE SET bookmark = COALESCE(excluded.bookmark, bookmark),
                    display_name = COALESCE(excluded.display_name, display_name)
                """, [path, bookmark, displayName])
            let id = try db.scalarInt("SELECT id FROM roots WHERE path = ?", [path]) ?? 0
            // Match in Swift with the same normalization as `coveringRoot` (photo paths are stored
            // as given, e.g. `/private/tmp/…` while the root is `/tmp/…`).
            let orphans = try db.query("SELECT id, path FROM photos WHERE root_id IS NULL", []) { ($0.int(0), $0.string(1)) }
            for (photoID, photoPath) in orphans where Self.path(photoPath, isUnderRoot: path) {
                try db.run("UPDATE photos SET root_id = ? WHERE id = ?", [id, photoID])
            }
            return id
        }
        postChange(.roots)
        return id
    }

    func updateRootBookmark(id: Int64, bookmark: Data) throws {
        try db.run("UPDATE roots SET bookmark = ? WHERE id = ?", [bookmark, id])
    }

    func allRoots() throws -> [Root] {
        try db.query("SELECT id, path, bookmark, display_name FROM roots ORDER BY path", [], Self.root(row:))
    }

    func root(id: Int64) throws -> Root? {
        try db.queryFirst("SELECT id, path, bookmark, display_name FROM roots WHERE id = ?", [id], Self.root(row:))
    }

    /// The root whose path is the longest prefix of `path` (a file or directory path).
    func root(for path: String) throws -> Root? {
        Self.coveringRoot(for: path, in: try allRoots())
    }

    /// Removes a root. Its photos keep existing (root_id becomes NULL).
    func removeRoot(id: Int64) throws {
        try db.run("DELETE FROM roots WHERE id = ?", [id])
        postChange(.roots)
    }

    static func coveringRoot(for path: String, in roots: [Root]) -> Root? {
        roots
            .filter { Self.path(path, isUnderRoot: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    // MARK: - Crop presets

    func allCropPresets() throws -> [CropPreset] {
        try db.query("SELECT id, name, ratio_w, ratio_h, sort_order FROM crop_presets ORDER BY sort_order, id") {
            CropPreset(id: $0.int(0), name: $0.string(1), ratioW: $0.double(2), ratioH: $0.double(3), sortOrder: Int($0.int(4)))
        }
    }

    @discardableResult
    func createCropPreset(name: String, ratioW: Double, ratioH: Double) throws -> Int64 {
        let id: Int64 = try db.transaction {
            let next = try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM crop_presets") ?? 0
            try db.run("INSERT INTO crop_presets(name, ratio_w, ratio_h, sort_order) VALUES (?,?,?,?)", [name, ratioW, ratioH, next])
            return db.lastInsertRowID
        }
        postChange(.cropPresets)
        return id
    }

    /// Updates name / ratio / sort order of an existing preset (matched by id).
    func updateCropPreset(_ preset: CropPreset) throws {
        try db.run("UPDATE crop_presets SET name = ?, ratio_w = ?, ratio_h = ?, sort_order = ? WHERE id = ?",
                   [preset.name, preset.ratioW, preset.ratioH, preset.sortOrder, preset.id])
        postChange(.cropPresets)
    }

    func deleteCropPreset(id: Int64) throws {
        try db.run("DELETE FROM crop_presets WHERE id = ?", [id])
        postChange(.cropPresets)
    }
}
