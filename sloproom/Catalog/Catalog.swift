//
//  Catalog.swift
//  sloproom
//
//  The photo catalog: one SQLite database plus a directory for caches (previews etc.).
//  All API is synchronous and thread-safe (serialized by SQLiteDatabase's lock);
//  do heavy calls off the main thread.
//
//  Feature code should add catalog API in its own `Catalog+Feature.swift` extension file
//  using `db` directly, and create feature-owned tables with `applyMigration(named:sql:)`.
//

import Foundation

/// What changed. Posted (on the main thread) as `Catalog.didChange` with the change in
/// `userInfo[Catalog.changeKey]`; `object` is the posting `Catalog`.
nonisolated enum CatalogChange: Sendable, Equatable {
    /// Flag / rating / edit settings / metadata of existing photos changed.
    case photosUpdated(Set<Int64>)
    /// Photos were inserted into or removed from the catalog.
    case photosInsertedOrRemoved
    /// Folder tree changed (create / rename / move / delete).
    case folders
    /// Photo membership of these folders changed.
    case folderMembership(Set<Int64>)
    case roots
    case cropPresets
}

nonisolated final class Catalog: @unchecked Sendable {
    static let didChange = Notification.Name("Catalog.didChange")
    static let changeKey = "change"

    /// Directory holding `Catalog.sqlite` and cache subdirectories (e.g. `Previews/`).
    let catalogDirectory: URL
    let databaseURL: URL
    /// Direct database access for `Catalog+Feature.swift` extensions.
    let db: SQLiteDatabase

    // MARK: - Opening

    /// `<Application Support>/Sloproom` (inside the app container when sandboxed).
    /// Override with the `SLOPROOM_CATALOG_DIR` environment variable (dev/testing).
    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SLOPROOM_CATALOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sloproom", isDirectory: true)
    }

    /// Opens (creating if needed) the app's catalog in the default location.
    static func openDefault() throws -> Catalog {
        try Catalog(directory: defaultDirectory)
    }

    /// Opens (creating if needed) a catalog stored in `directory` (`<directory>/Catalog.sqlite`).
    /// Use a temp directory in test harnesses.
    static func open(at directory: URL) throws -> Catalog {
        try Catalog(directory: directory)
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalogDirectory = directory
        databaseURL = directory.appendingPathComponent("Catalog.sqlite")
        db = try SQLiteDatabase(path: databaseURL.path)
        try migrate()
    }

    /// Closes the database (Import Catalog swaps the file). Later calls on this instance throw.
    func close() {
        db.close()
    }

    /// Core schema version this app writes (`PRAGMA user_version`). Catalogs with a higher
    /// version come from a newer app and are refused by Import Catalog.
    static var schemaVersion: Int { migrations.count }

    /// Subdirectory of `catalogDirectory`, created on demand (e.g. `cacheDirectory("Previews")`).
    func cacheDirectory(_ name: String) -> URL {
        let url = catalogDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Change notifications

    /// Posts `Catalog.didChange` asynchronously on the main queue.
    func postChange(_ change: CatalogChange) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Catalog.didChange, object: self, userInfo: [Catalog.changeKey: change])
        }
    }

    /// Extracts the payload from a `Catalog.didChange` notification.
    static func change(from note: Notification) -> CatalogChange? {
        note.userInfo?[changeKey] as? CatalogChange
    }

    // MARK: - Migrations

    /// Core schema versions, applied in order, tracked by `PRAGMA user_version`.
    /// Append only; never edit a shipped entry.
    private static let migrations: [String] = [
        // v1 — initial schema
        """
        CREATE TABLE roots(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            bookmark BLOB NULL,
            display_name TEXT
        );
        CREATE TABLE photos(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            root_id INTEGER NULL REFERENCES roots(id) ON DELETE SET NULL,
            file_name TEXT,
            file_size INTEGER,
            capture_date REAL NULL,
            import_date REAL NOT NULL,
            width INTEGER,
            height INTEGER,
            orientation INTEGER DEFAULT 1,
            camera_make TEXT,
            camera_model TEXT,
            lens TEXT,
            iso INTEGER,
            shutter REAL,
            aperture REAL,
            focal_length REAL,
            flag INTEGER NOT NULL DEFAULT 0,
            rating INTEGER NOT NULL DEFAULT 0,
            edit_settings TEXT NULL,
            edit_version INTEGER NOT NULL DEFAULT 0,
            sidecar_path TEXT NULL,
            lr_image_id INTEGER NULL
        );
        CREATE TABLE folders(
            id INTEGER PRIMARY KEY,
            parent_id INTEGER NULL REFERENCES folders(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            lr_collection_id INTEGER NULL
        );
        CREATE TABLE folder_photos(
            folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(folder_id, photo_id)
        );
        CREATE TABLE crop_presets(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            ratio_w REAL NOT NULL,
            ratio_h REAL NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE applied_migrations(
            name TEXT PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        CREATE INDEX idx_photos_capture_date ON photos(capture_date);
        CREATE INDEX idx_photos_import_date ON photos(import_date);
        CREATE INDEX idx_photos_flag ON photos(flag);
        CREATE INDEX idx_photos_root ON photos(root_id);
        CREATE INDEX idx_folders_parent ON folders(parent_id);
        CREATE INDEX idx_folder_photos_photo ON folder_photos(photo_id);
        INSERT INTO crop_presets(name, ratio_w, ratio_h, sort_order) VALUES
            ('Instagram Story', 9, 16, 0),
            ('Instagram Post Square', 1, 1, 1),
            ('Vertical 4:5', 4, 5, 2),
            ('Horizontal 3:2', 3, 2, 3);
        """,
    ]

    private func migrate() throws {
        let current = Int(try db.scalarInt("PRAGMA user_version") ?? 0)
        guard current < Self.migrations.count else { return }
        try db.transaction {
            for version in current..<Self.migrations.count {
                try db.execute(Self.migrations[version])
            }
            try db.execute("PRAGMA user_version = \(Self.migrations.count)")
        }
    }

    /// Idempotently applies a feature-owned migration identified by a unique `name`
    /// (e.g. "previews.v1"). Safe to call on every launch; runs `sql` at most once per catalog.
    /// Prefer this over editing the core migration list, so features don't conflict.
    func applyMigration(named name: String, sql: String) throws {
        try db.transaction {
            let done = try db.scalarInt("SELECT COUNT(*) FROM applied_migrations WHERE name = ?", [name]) ?? 0
            guard done == 0 else { return }
            try db.execute(sql)
            try db.run("INSERT INTO applied_migrations(name, applied_at) VALUES (?, ?)", [name, Date()])
        }
    }
}
