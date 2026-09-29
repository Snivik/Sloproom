//
//  CatalogTransfer.swift
//  sloproom
//
//  Catalog portability (engine; no SwiftUI/AppKit, harness: Tools/catalog_transfer_check.swift).
//  Edits live ONLY in the catalog (no XMP / sidecars), so moving a library to another Mac is
//  Export Catalog → Import Catalog:
//
//  - Export: `VACUUM INTO` a consistent snapshot of the live (open) catalog in the container work
//    directory, add a `catalog_info` key/value table to the SNAPSHOT (format / app / schema
//    version, exported at, source Mac, counts), switch it to a single-file rollback journal,
//    integrity-check it, then move it to the destination atomically. Previews are not included.
//  - Import: copy the picked file into the container staging directory (never opened in place),
//    validate (tables, `PRAGMA integrity_check`, schema not newer than this app), summarize.
//  - Replace: back up the live catalog (`VACUUM INTO Backups/Catalog-YYYYMMDD-HHMMSS.sqlite`,
//    last 10 kept), close it, swap the files (stale -wal/-shm removed), reopen (older schemas are
//    migrated by `Catalog.open`). Any failure after closing restores the backup and reopens it.
//

import Foundation
import SQLite3

/// What a catalog file contains (read from the file itself; export metadata from `catalog_info`).
nonisolated struct CatalogInfo: Sendable, Equatable {
    /// `catalog_info.format_version` (nil for a plain Catalog.sqlite that was never exported).
    var formatVersion: Int?
    var appVersion: String?
    var appBuild: String?
    var exportedAt: Date?
    var sourceMac: String?
    /// `PRAGMA user_version` of the file.
    var schemaVersion: Int
    var photoCount = 0
    var editedPhotoCount = 0
    var pickedCount = 0
    var rejectedCount = 0
    var folderCount = 0
    var folderMembershipCount = 0
    var rootCount = 0

    var isExport: Bool { formatVersion != nil }
}

nonisolated struct CatalogExportResult: Sendable {
    var url: URL
    var info: CatalogInfo
    var bytes: Int64
    var seconds: Double
    /// How the file reached the destination (diagnostics): "replace", "rename" or "copy".
    var writeMethod: String
}

/// A validated catalog file copied into the staging directory, ready to replace the live one.
nonisolated struct CatalogImportCandidate: Sendable, Identifiable {
    let id = UUID()
    var sourceURL: URL
    var stagedURL: URL
    var info: CatalogInfo
    var roots: [Root]
    var fileBytes: Int64
    var fileDate: Date?
    /// Set when the source is a WAL-mode database whose `-wal` file could not be read.
    var warning: String?
    var needsMigration: Bool { info.schemaVersion < Catalog.schemaVersion }
}

nonisolated enum CatalogTransferError: Error, CustomStringConvertible, LocalizedError {
    case notACatalog(String)
    case damaged(String)
    case newerSchema(found: Int, supported: Int)
    case newerFormat(found: Int, supported: Int)
    case writeFailed(String)
    /// Replacing failed; the previous catalog was restored (`reopened`, may be nil if even that failed).
    case replaceFailed(String, backup: URL, reopened: Catalog?)

    var description: String {
        switch self {
        case .notACatalog(let why): "This file is not a Sloproom catalog (\(why))."
        case .damaged(let why): "The catalog file is damaged: \(why)"
        case .newerSchema(let found, let supported):
            "This catalog was created by a newer version of Sloproom (catalog schema \(found); this app supports up to \(supported)). Update Sloproom on this Mac, then import it again."
        case .newerFormat(let found, let supported):
            "This catalog export uses a newer format (version \(found); this app reads up to \(supported)). Update Sloproom on this Mac, then import it again."
        case .writeFailed(let why): "The catalog could not be written: \(why)"
        case .replaceFailed(let why, let backup, let reopened):
            reopened == nil
                ? "Replacing the catalog failed (\(why)) and the previous catalog could not be reopened. It is backed up at \(backup.path). Quit and relaunch Sloproom."
                : "Replacing the catalog failed (\(why)). Your previous catalog was restored."
        }
    }
    var errorDescription: String? { description }
}

nonisolated enum CatalogTransfer {
    static let fileExtension = "sloproomcatalog"
    /// `catalog_info.format_version` written by this app. Bump when the export format changes
    /// incompatibly (older apps then refuse the file with a clear message).
    static let formatVersion = 1
    static let backupsToKeep = 10
    /// Tables every Sloproom catalog has (core schema v1).
    static let requiredTables: Set<String> = ["photos", "folders", "folder_photos", "roots", "applied_migrations"]

    /// "Sloproom Catalog 2026-09-29.sloproomcatalog"
    static func defaultExportName(date: Date = Date()) -> String {
        "Sloproom Catalog \(stamp(date, "yyyy-MM-dd")).\(fileExtension)"
    }

    /// `<catalogDirectory>/Backups` (= `<Application Support>/Sloproom/Backups` for the default catalog).
    static func backupsDirectory(for catalog: Catalog) -> URL {
        catalog.catalogDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    /// `<catalogDirectory>/Transfer` — snapshots and staged imports (same volume as the catalog,
    /// so installing is an atomic rename).
    static func workDirectory(for catalog: Catalog) -> URL {
        catalog.catalogDirectory.appendingPathComponent("Transfer", isDirectory: true)
    }

    // MARK: - Export

    /// Writes a consistent single-file snapshot of the open `catalog` to `destination`
    /// (replacing an existing file). Call off the main thread.
    static func exportCatalog(_ catalog: Catalog, to destination: URL, appVersion: String, appBuild: String,
                              sourceMac: String, now: Date = Date()) throws -> CatalogExportResult {
        let start = Date()
        let work = workDirectory(for: catalog)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tmp = work.appendingPathComponent("export-\(UUID().uuidString).sqlite")
        defer { removeDatabaseFiles(tmp) }
        try snapshot(catalog, to: tmp)
        let info = try finalizeSnapshot(at: tmp, appVersion: appVersion, appBuild: appBuild, sourceMac: sourceMac, exportedAt: now)
        let method = try place(tmp, at: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
        return CatalogExportResult(url: destination, info: info, bytes: size ?? 0,
                                   seconds: Date().timeIntervalSince(start), writeMethod: method)
    }

    /// `VACUUM INTO` a new file (must not exist). Consistent even while other threads write.
    static func snapshot(_ catalog: Catalog, to url: URL) throws {
        removeDatabaseFiles(url)
        do {
            try catalog.db.run("VACUUM INTO ?", [url.path])
        } catch {
            throw CatalogTransferError.writeFailed(String(describing: error))
        }
    }

    /// Adds `catalog_info`, switches the snapshot to a rollback journal (one self-contained file),
    /// checks integrity and closes it. Returns what it contains.
    private static func finalizeSnapshot(at url: URL, appVersion: String, appBuild: String,
                                         sourceMac: String, exportedAt: Date) throws -> CatalogInfo {
        let db = try SQLiteDatabase(path: url.path)
        defer { db.close() }
        var info = try readInfo(db)
        info.formatVersion = formatVersion
        info.appVersion = appVersion
        info.appBuild = appBuild
        info.exportedAt = exportedAt
        info.sourceMac = sourceMac
        let iso = ISO8601DateFormatter().string(from: exportedAt)
        let values: [(String, String)] = [
            ("format", "sloproom.catalog"),
            ("format_version", String(formatVersion)),
            ("app_version", appVersion),
            ("app_build", appBuild),
            ("schema_version", String(info.schemaVersion)),
            ("exported_at", iso),
            ("exported_at_unix", String(exportedAt.timeIntervalSince1970)),
            ("source_mac", sourceMac),
            ("export_id", UUID().uuidString),
            ("photo_count", String(info.photoCount)),
            ("edited_photo_count", String(info.editedPhotoCount)),
            ("folder_count", String(info.folderCount)),
            ("root_count", String(info.rootCount)),
        ]
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS catalog_info(key TEXT PRIMARY KEY, value TEXT NOT NULL); DELETE FROM catalog_info;")
            for (k, v) in values { try db.run("INSERT INTO catalog_info(key, value) VALUES (?, ?)", [k, v]) }
        }
        try db.execute("PRAGMA journal_mode=DELETE")
        try checkIntegrity(db)
        return info
    }

    /// Moves the finished file `tmp` to `destination`: safe-save through an item replacement
    /// directory, else a hidden sibling + rename, else a plain copy (a sandboxed save-panel grant
    /// may cover only the chosen file). Returns the method used.
    private static func place(_ tmp: URL, at destination: URL) throws -> String {
        let fm = FileManager.default
        var problems: [String] = []
        // 1. Safe save (what NSDocument does): copy next to the destination's volume, then replace.
        do {
            let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
            defer { try? fm.removeItem(at: dir) }
            let staged = dir.appendingPathComponent(destination.lastPathComponent)
            try fm.copyItem(at: tmp, to: staged)
            try fsyncFile(staged)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
            return "replace"
        } catch { problems.append("replace: \(error.localizedDescription)") }
        // 2. Hidden sibling + atomic rename.
        let sibling = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).sloproom-tmp-\(UUID().uuidString.prefix(8))")
        do {
            try fm.copyItem(at: tmp, to: sibling)
            try fsyncFile(sibling)
            guard rename(sibling.path, destination.path) == 0 else {
                let err = String(cString: strerror(errno))
                try? fm.removeItem(at: sibling)
                throw CatalogTransferError.writeFailed(err)
            }
            return "rename"
        } catch { problems.append("rename: \(error.localizedDescription)"); try? fm.removeItem(at: sibling) }
        // 3. Write the destination file directly (only the chosen file is writable).
        do {
            let data = try Data(contentsOf: tmp, options: .alwaysMapped)
            try data.write(to: destination, options: [])
            try fsyncFile(destination)
            return "copy"
        } catch {
            problems.append("copy: \(error.localizedDescription)")
            throw CatalogTransferError.writeFailed(problems.joined(separator: "; "))
        }
    }

    // MARK: - Import (validate + stage)

    /// Copies `source` (a `.sloproomcatalog` or a plain `Catalog.sqlite`) into `stagingDirectory`,
    /// validates it and summarizes it. The staged copy is a single file (rollback journal).
    static func stageImport(from source: URL, stagingDirectory: URL) throws -> CatalogImportCandidate {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        cleanStaleStagedFiles(in: stagingDirectory)
        let staged = stagingDirectory.appendingPathComponent("import-\(UUID().uuidString).sqlite")
        let attributes = try? fm.attributesOfItem(atPath: source.path)
        do {
            try fm.copyItem(at: source, to: staged)
        } catch {
            throw CatalogTransferError.notACatalog("it could not be read: \(error.localizedDescription)")
        }
        var warning: String?
        let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
        if isWALMode(staged) {
            // Changes of a catalog that is open (or wasn't closed cleanly) may still be in its -wal.
            if fm.fileExists(atPath: sourceWAL.path) {
                do { try fm.copyItem(at: sourceWAL, to: URL(fileURLWithPath: staged.path + "-wal")) }
                catch { warning = "Sloproom couldn't read “\(sourceWAL.lastPathComponent)” next to this file, so the most recent changes may be missing. Quit Sloproom on the other Mac and use File > Export Catalog… there." }
            }
        }
        do {
            let (info, roots) = try validate(databaseAt: staged)
            return CatalogImportCandidate(sourceURL: source, stagedURL: staged, info: info, roots: roots,
                                          fileBytes: (attributes?[.size] as? Int64) ?? 0,
                                          fileDate: attributes?[.modificationDate] as? Date, warning: warning)
        } catch {
            removeDatabaseFiles(staged)
            throw error
        }
    }

    /// Validates a catalog file and returns its info and roots. Leaves it as ONE file in rollback
    /// journal mode (checkpoints any -wal). Throws `CatalogTransferError`.
    static func validate(databaseAt url: URL) throws -> (CatalogInfo, [Root]) {
        let db: SQLiteDatabase
        do { db = try SQLiteDatabase(path: url.path) } catch {
            throw CatalogTransferError.notACatalog(sqliteReason(error))
        }
        defer { db.close() }
        let tables: Set<String>
        do {
            tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) })
        } catch { throw CatalogTransferError.notACatalog(sqliteReason(error)) }
        let missing = requiredTables.subtracting(tables)
        guard missing.isEmpty else {
            throw CatalogTransferError.notACatalog("missing tables: \(missing.sorted().joined(separator: ", "))")
        }
        let photoColumns = Set(try db.query("PRAGMA table_info(photos)") { $0.string(1) })
        let needed: Set<String> = ["id", "path", "flag", "edit_settings", "edit_version", "root_id"]
        guard needed.isSubset(of: photoColumns) else {
            throw CatalogTransferError.notACatalog("unexpected photos table")
        }
        let info = try readInfo(db)
        guard info.schemaVersion >= 1 else { throw CatalogTransferError.notACatalog("no schema version") }
        if info.schemaVersion > Catalog.schemaVersion {
            throw CatalogTransferError.newerSchema(found: info.schemaVersion, supported: Catalog.schemaVersion)
        }
        if let f = info.formatVersion, f > formatVersion {
            throw CatalogTransferError.newerFormat(found: f, supported: formatVersion)
        }
        try checkIntegrity(db)
        let roots = try db.query("SELECT id, path, bookmark, display_name FROM roots ORDER BY path") {
            Root(id: $0.int(0), path: $0.string(1), bookmark: $0.data(2), displayName: $0.stringOrNil(3))
        }
        try db.execute("PRAGMA journal_mode=DELETE")
        return (info, roots)
    }

    /// Counts + `catalog_info` of an open database.
    static func readInfo(_ db: SQLiteDatabase) throws -> CatalogInfo {
        var info = CatalogInfo(schemaVersion: Int(try db.scalarInt("PRAGMA user_version") ?? 0))
        let hasInfoTable = (try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'catalog_info'") ?? 0) > 0
        if hasInfoTable {
            let pairs = try db.query("SELECT key, value FROM catalog_info") { ($0.string(0), $0.string(1)) }
            let kv = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
            info.formatVersion = kv["format_version"].flatMap { Int($0) }
            info.appVersion = kv["app_version"]
            info.appBuild = kv["app_build"]
            info.sourceMac = kv["source_mac"]
            info.exportedAt = kv["exported_at_unix"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                ?? kv["exported_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        info.photoCount = Int(try db.scalarInt("SELECT COUNT(*) FROM photos") ?? 0)
        info.editedPhotoCount = Int(try db.scalarInt("SELECT COUNT(*) FROM photos WHERE edit_settings IS NOT NULL") ?? 0)
        info.pickedCount = Int(try db.scalarInt("SELECT COUNT(*) FROM photos WHERE flag = 1") ?? 0)
        info.rejectedCount = Int(try db.scalarInt("SELECT COUNT(*) FROM photos WHERE flag = -1") ?? 0)
        info.folderCount = Int(try db.scalarInt("SELECT COUNT(*) FROM folders") ?? 0)
        info.folderMembershipCount = Int(try db.scalarInt("SELECT COUNT(*) FROM folder_photos") ?? 0)
        info.rootCount = Int(try db.scalarInt("SELECT COUNT(*) FROM roots") ?? 0)
        return info
    }

    /// Info of an open catalog (for "the current catalog has …").
    static func info(of catalog: Catalog) throws -> CatalogInfo { try readInfo(catalog.db) }

    private static func checkIntegrity(_ db: SQLiteDatabase) throws {
        let result = try db.query("PRAGMA integrity_check(20)") { $0.string(0) }
        guard result == ["ok"] else { throw CatalogTransferError.damaged(result.prefix(5).joined(separator: "; ")) }
        let fk = try db.query("PRAGMA foreign_key_check") { $0.string(0) }
        guard fk.isEmpty else { throw CatalogTransferError.damaged("\(fk.count) broken references (\(Set(fk).sorted().joined(separator: ", ")))") }
    }

    // MARK: - Replace

    /// Backs up `live`, closes it and installs `candidate` in its directory, then reopens.
    /// Returns the new open catalog. On failure after closing, restores the backup and throws
    /// `.replaceFailed(…, reopened:)` with the reopened previous catalog. Call off the main thread;
    /// `live` must not be used afterwards.
    static func replaceCatalog(_ live: Catalog, with candidate: CatalogImportCandidate,
                               now: Date = Date()) throws -> (catalog: Catalog, backup: URL) {
        let directory = live.catalogDirectory
        let backup = try backupCatalog(live, into: backupsDirectory(for: live), date: now)
        live.close()
        do {
            try install(candidate.stagedURL, asCatalogIn: directory)
            let catalog = try Catalog.open(at: directory)
            let reopened = try readInfo(catalog.db)
            guard reopened.photoCount == candidate.info.photoCount, reopened.folderCount == candidate.info.folderCount else {
                throw CatalogTransferError.damaged("expected \(candidate.info.photoCount) photos, found \(reopened.photoCount)")
            }
            return (catalog, backup)
        } catch {
            var reopened: Catalog?
            do {
                let restore = directory.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
                try FileManager.default.copyItem(at: backup, to: restore)
                try install(restore, asCatalogIn: directory)
                reopened = try Catalog.open(at: directory)
            } catch {}
            throw CatalogTransferError.replaceFailed(String(describing: error), backup: backup, reopened: reopened)
        }
    }

    /// `VACUUM INTO <backups>/Catalog-YYYYMMDD-HHMMSS.sqlite`; keeps the newest `keep` backups.
    static func backupCatalog(_ catalog: Catalog, into backups: URL, date: Date = Date(), keep: Int = backupsToKeep) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let base = "Catalog-\(stamp(date, "yyyyMMdd-HHmmss"))"
        var url = backups.appendingPathComponent(base + ".sqlite")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = backups.appendingPathComponent("\(base)-\(n).sqlite"); n += 1
        }
        try snapshot(catalog, to: url)
        try? setJournalModeDelete(url)
        pruneBackups(in: backups, keep: keep, sparing: url)
        return url
    }

    /// Backup files, newest first.
    static func backups(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("Catalog-") && $0.hasSuffix(".sqlite") }
            .sorted(by: >)   // Catalog-YYYYMMDD-HHMMSS[-n] sorts chronologically
            .map { directory.appendingPathComponent($0) }
    }

    /// Deletes all but the newest `keep` backups (never `sparing`, the one just written).
    static func pruneBackups(in directory: URL, keep: Int, sparing: URL? = nil) {
        let all = backups(in: directory).filter { $0.lastPathComponent != sparing?.lastPathComponent }
        for old in all.dropFirst(max(keep, 1) - (sparing == nil ? 0 : 1)) { removeDatabaseFiles(old) }
    }

    /// Atomically makes `file` (single-file database on the same volume) the catalog of
    /// `directory`. The catalog there must be closed. Removes stale -wal/-shm first (a leftover
    /// WAL would be replayed onto the new file).
    static func install(_ file: URL, asCatalogIn directory: URL) throws {
        let target = directory.appendingPathComponent("Catalog.sqlite")
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = target.path + suffix
            if FileManager.default.fileExists(atPath: side) { try FileManager.default.removeItem(atPath: side) }
        }
        guard rename(file.path, target.path) == 0 else {
            throw CatalogTransferError.writeFailed("rename: \(String(cString: strerror(errno)))")
        }
        // A rollback-journal database may leave an empty -shm from its WAL days.
        for suffix in ["-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
    }

    /// Moves `<directory>/Previews` aside (previews are keyed by photo id, which differs between
    /// catalogs) and deletes it in the background. Returns immediately.
    static func discardPreviewsDirectory(in directory: URL, synchronously: Bool = false) {
        let fm = FileManager.default
        let previews = directory.appendingPathComponent("Previews", isDirectory: true)
        guard fm.fileExists(atPath: previews.path) else { return }
        let trash = directory.appendingPathComponent(".Previews-discarded-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.moveItem(at: previews, to: trash)) != nil else {
            try? fm.removeItem(at: previews)
            return
        }
        if synchronously { try? fm.removeItem(at: trash); return }
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: trash) }
    }

    /// Deletes a staged / temporary database and its side files.
    static func removeDatabaseFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    // MARK: - Helpers

    private static func cleanStaleStagedFiles(in directory: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        for name in names where name.hasPrefix("import-") || name.hasPrefix("export-") {
            let url = directory.appendingPathComponent(name)
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if date < dayAgo { try? fm.removeItem(at: url) }
        }
    }

    /// SQLite header byte 18 == 2 → WAL mode.
    private static func isWALMode(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2
    }

    private static func setJournalModeDelete(_ url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        defer { db.close() }
        try db.execute("PRAGMA journal_mode=DELETE")
    }

    private static func fsyncFile(_ url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        try h.synchronize()
    }

    private static func sqliteReason(_ error: Error) -> String {
        if let e = error as? SQLiteError { return e.code == SQLITE_NOTADB ? "not a database" : e.message }
        return String(describing: error)
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}
