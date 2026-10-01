//
//  vcopies_check.swift
//  Headless test of virtual copies: schema v2 migration (fresh v1 catalog + a COPY of the
//  realistic catalog), creating copies (edits / flags copied, independent afterwards, master_id
//  flattening, copy numbering, rename, initial-settings seam), sorting next to the master,
//  path dedupe of imports (insertPhotos, photoID, import fingerprints, Lightroom import),
//  relink rewriting copies, removal cascade, preview seeding / cleanup, export file names.
//
//    Tools/harness.sh /private/tmp/claude-501/out-vcopies/vcopies_check Tools/vcopies_check.swift \
//        sloproom/VirtualCopies/Catalog+VirtualCopies.swift sloproom/VirtualCopies/VirtualCopyPreviews.swift \
//        sloproom/Import/Catalog+Import.swift sloproom/LightroomImport/RootAccess.swift \
//        sloproom/LightroomImport/LightroomCatalogReader.swift sloproom/LightroomImport/LightroomImportPlan.swift \
//        sloproom/LightroomImport/Catalog+LightroomImport.swift sloproom/Export/ExportEngine.swift \
//        sloproom/Develop/Crop/CropMath.swift
//    /private/tmp/claude-501/out-vcopies/vcopies_check [realistic-catalog-dir to COPY] [sample.jpg] [out-dir]
//
//  Defaults: ~/Library/Containers/dev.snivik.sloproom/Data/tmp/vcopies/pristine (copied first, never
//  opened in place), …/Data/tmp/folders/photos/L1090230.JPG (read only), /private/tmp/claude-501/out-vcopies.
//

import Foundation
import CoreGraphics

@main
struct VirtualCopiesCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t = Date()
        let value = try body()
        print(String(format: "  %@: %.1f ms", label, Date().timeIntervalSince(t) * 1000))
        return value
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let realistic = URL(fileURLWithPath: args.count > 1 ? args[1] : "\(home)/Library/Containers/dev.snivik.sloproom/Data/tmp/vcopies/pristine")
        let sample = URL(fileURLWithPath: args.count > 2 ? args[2] : "\(home)/Library/Containers/dev.snivik.sloproom/Data/tmp/folders/photos/L1090230.JPG")
        let out = URL(fileURLWithPath: args.count > 3 ? args[3] : "/private/tmp/claude-501/out-vcopies")
        let run = out.appendingPathComponent("run-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }

        try freshMigration(run.appendingPathComponent("v1"))
        try realisticMigration(from: realistic, into: run.appendingPathComponent("realistic"))
        try copies(run.appendingPathComponent("copies"))
        try imports(run.appendingPathComponent("imports"))
        try relink(run.appendingPathComponent("relink"))
        try removal(run.appendingPathComponent("removal"))
        try previews(run.appendingPathComponent("previews"))
        try export(run.appendingPathComponent("export"), sample: sample)

        print(failures == 0 ? "ALL VIRTUAL COPY CHECKS PASSED" : "\(failures) FAILURE(S)")
        if failures > 0 { exit(1) }
    }

    // MARK: - Helpers

    static func photo(_ name: String, dir: String = "/vc/photos", day: Double = 0) -> Photo {
        var p = Photo(path: "\(dir)/\(name)")
        p.captureDate = Date(timeIntervalSince1970: 1_750_000_000 + day * 60)
        p.importDate = Date(timeIntervalSince1970: 1_760_000_000)
        p.width = 6000; p.height = 4000
        return p
    }

    static func editedSettings(exposure: Double, crop: NormRect = .full) -> EditSettings {
        var s = EditSettings()
        s.tone.exposure = exposure
        s.geometry.crop = crop
        return s
    }

    /// Everything that must survive the migration, per photo / membership (sorted by id).
    static func fingerprint(_ db: SQLiteDatabase) throws -> (photos: [String], members: [String], folders: Int, roots: Int) {
        let photos = try db.query("""
            SELECT id, path, IFNULL(root_id,0), IFNULL(file_name,''), IFNULL(capture_date,0), import_date, flag, rating,
                IFNULL(edit_settings,''), edit_version, IFNULL(sidecar_path,''), IFNULL(lr_image_id,0) FROM photos ORDER BY id
            """) { r in (0..<12).map { r.isNull($0) ? "∅" : r.stringOrNil($0) ?? "" }.joined(separator: "|") }
        let members = try db.query("SELECT folder_id, photo_id, sort_order FROM folder_photos ORDER BY folder_id, photo_id") {
            "\($0.int(0))/\($0.int(1))/\($0.int(2))"
        }
        let folders = Int(try db.scalarInt("SELECT COUNT(*) FROM folders") ?? 0)
        let roots = Int(try db.scalarInt("SELECT COUNT(*) FROM roots") ?? 0)
        return (photos, members, folders, roots)
    }

    static func schemaChecks(_ c: Catalog, _ label: String) throws {
        check(try c.db.scalarInt("PRAGMA user_version") == Int64(Catalog.schemaVersion), "\(label): user_version = \(Catalog.schemaVersion)")
        check(try c.db.scalarInt("PRAGMA foreign_keys") == 1, "\(label): foreign keys back ON")
        let cols = try c.db.query("PRAGMA table_info(photos)") { $0.string(1) }
        check(cols.contains("master_id") && cols.contains("copy_name"), "\(label): master_id + copy_name columns")
        let indexes = try c.db.query("SELECT name, IFNULL(sql,'') FROM sqlite_master WHERE type = 'index' AND tbl_name = 'photos'") { ($0.string(0), $0.string(1)) }
        let names = Set(indexes.map(\.0))
        check(["idx_photos_capture_date", "idx_photos_import_date", "idx_photos_flag", "idx_photos_root",
               "idx_photos_master_path", "idx_photos_master"].allSatisfy(names.contains), "\(label): all photo indexes recreated (\(names.sorted()))")
        check(indexes.first { $0.0 == "idx_photos_master_path" }?.1.contains("WHERE master_id IS NULL") == true, "\(label): partial unique index on path")
        check(!names.contains { $0.hasPrefix("sqlite_autoindex_photos") }, "\(label): no UNIQUE(path) autoindex left")
        check(try c.db.query("PRAGMA integrity_check") { $0.string(0) } == ["ok"], "\(label): integrity_check ok")
        check(try c.db.query("PRAGMA foreign_key_check") { $0.string(0) }.isEmpty, "\(label): foreign_key_check clean")
        let fpSQL = try c.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'folder_photos' AND sql LIKE '%REFERENCES photos(id)%'") ?? 0
        check(fpSQL == 1, "\(label): folder_photos still references photos(id)")
    }

    // MARK: - Migration of a fresh v1 catalog

    static let v1Schema = """
        CREATE TABLE roots(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, bookmark BLOB NULL, display_name TEXT);
        CREATE TABLE photos(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
            root_id INTEGER NULL REFERENCES roots(id) ON DELETE SET NULL, file_name TEXT, file_size INTEGER,
            capture_date REAL NULL, import_date REAL NOT NULL, width INTEGER, height INTEGER, orientation INTEGER DEFAULT 1,
            camera_make TEXT, camera_model TEXT, lens TEXT, iso INTEGER, shutter REAL, aperture REAL, focal_length REAL,
            flag INTEGER NOT NULL DEFAULT 0, rating INTEGER NOT NULL DEFAULT 0, edit_settings TEXT NULL,
            edit_version INTEGER NOT NULL DEFAULT 0, sidecar_path TEXT NULL, lr_image_id INTEGER NULL);
        CREATE TABLE folders(id INTEGER PRIMARY KEY, parent_id INTEGER NULL REFERENCES folders(id) ON DELETE CASCADE,
            name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, lr_collection_id INTEGER NULL);
        CREATE TABLE folder_photos(folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE, sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(folder_id, photo_id));
        CREATE TABLE crop_presets(id INTEGER PRIMARY KEY, name TEXT NOT NULL, ratio_w REAL NOT NULL, ratio_h REAL NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE applied_migrations(name TEXT PRIMARY KEY, applied_at REAL NOT NULL);
        CREATE INDEX idx_photos_capture_date ON photos(capture_date);
        CREATE INDEX idx_photos_import_date ON photos(import_date);
        CREATE INDEX idx_photos_flag ON photos(flag);
        CREATE INDEX idx_photos_root ON photos(root_id);
        CREATE INDEX idx_folders_parent ON folders(parent_id);
        CREATE INDEX idx_folder_photos_photo ON folder_photos(photo_id);
        PRAGMA user_version = 1;
        """

    static func freshMigration(_ dir: URL) throws {
        print("Migration: fresh v1 catalog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: dir.appendingPathComponent("Catalog.sqlite").path)
            try db.execute(v1Schema)
            try db.run("INSERT INTO roots(id, path) VALUES (3, '/vc')")
            let json = editedSettings(exposure: 0.7).jsonString()
            // Non-contiguous ids on purpose (gaps after deletions must survive).
            for (id, name, flag, edits) in [(5, "A.DNG", 1, json), (9, "B.DNG", -1, nil), (12, "C.DNG", 0, json), (40, "D.JPG", 1, nil)] as [(Int, String, Int, String?)] {
                try db.run("""
                    INSERT INTO photos(id, path, root_id, file_name, import_date, capture_date, flag, rating, edit_settings, edit_version, lr_image_id)
                    VALUES (?,?,3,?,1760000000,?,?,?,?,?,?)
                    """, [id, "/vc/\(name)", name, 1_750_000_000 + id, flag, id % 6, edits, edits == nil ? 0 : 4, id * 10])
            }
            try db.run("INSERT INTO folders(id, name, created_at) VALUES (2, 'Trip', 0)")
            try db.run("INSERT INTO folders(id, parent_id, name, created_at) VALUES (7, 2, 'Picks', 0)")
            for (f, p, o) in [(2, 5, 0), (2, 12, 1), (7, 40, 0), (7, 5, 1)] {
                try db.run("INSERT INTO folder_photos(folder_id, photo_id, sort_order) VALUES (?,?,?)", [f, p, o])
            }
            db.close()
        }
        let before = try { () throws -> (photos: [String], members: [String], folders: Int, roots: Int) in
            let db = try SQLiteDatabase(path: dir.appendingPathComponent("Catalog.sqlite").path)
            defer { db.close() }
            return try fingerprint(db)
        }()
        let catalog = try time("open + migrate v1 → v\(Catalog.schemaVersion)") { try Catalog.open(at: dir) }
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)) ?? []
        let backup = backups.first { $0.hasPrefix("Catalog-before-v\(Catalog.schemaVersion)-") }
        check(backup != nil, "pre-migration backup written (\(backup ?? "none"))")
        if let backup {
            let db = try SQLiteDatabase(path: dir.appendingPathComponent("Backups").appendingPathComponent(backup).path)
            check(try fingerprint(db).photos == before.photos && (try db.scalarInt("PRAGMA user_version")) == 1, "backup is the untouched v1 catalog")
            db.close()
        }
        let after = try fingerprint(catalog.db)
        check(after.photos == before.photos, "photos identical (ids, paths, flags, ratings, edits, versions) — \(after.photos.count) rows")
        check(after.members == before.members, "folder memberships identical (\(after.members.count))")
        check(after.folders == before.folders && after.roots == before.roots, "folders / roots unchanged")
        check(try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE master_id IS NOT NULL OR copy_name IS NOT NULL") == 0, "every migrated photo is a master")
        try schemaChecks(catalog, "fresh v1")
        // FK cascade still works after the rebuild (folder_photos → photos).
        try catalog.removePhotos(ids: [5])
        check(try catalog.db.scalarInt("SELECT COUNT(*) FROM folder_photos WHERE photo_id = 5") == 0, "deleting a photo still cascades to folder_photos")
        check(try catalog.insertPhoto(photo("A.DNG", dir: "/vc")) != 5, "path free again after removal (new id)")
        check(try catalog.insertPhoto(photo("B.DNG", dir: "/vc")) == 9, "upsert by path returns the existing master id")
        catalog.close()
        let reopened = try Catalog.open(at: dir)
        check(try reopened.db.scalarInt("PRAGMA user_version") == Int64(Catalog.schemaVersion), "reopen: no second migration")
        reopened.close()
    }

    // MARK: - Migration of a copy of the realistic catalog

    static func realisticMigration(from source: URL, into dir: URL) throws {
        print("Migration: COPY of the realistic catalog \(source.path)")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appendingPathComponent("Catalog.sqlite").path) else {
            print("  SKIP (no catalog at \(source.path))"); return
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = source.appendingPathComponent("Catalog.sqlite\(suffix)")
            if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: dir.appendingPathComponent("Catalog.sqlite\(suffix)")) }
        }
        let before = try { () throws -> (photos: [String], members: [String], folders: Int, roots: Int, version: Int64) in
            let db = try SQLiteDatabase(path: dir.appendingPathComponent("Catalog.sqlite").path)
            defer { db.close() }
            let f = try fingerprint(db)
            return (f.photos, f.members, f.folders, f.roots, try db.scalarInt("PRAGMA user_version") ?? 0)
        }()
        print("  before: v\(before.version), \(before.photos.count) photos, \(before.members.count) memberships, \(before.folders) folders, \(before.roots) roots")
        let catalog = try time("open + migrate \(before.photos.count) photos") { try Catalog.open(at: dir) }
        let after = try fingerprint(catalog.db)
        check(after.photos.count == before.photos.count && after.photos == before.photos, "all \(after.photos.count) photos identical (ids, paths, flags, ratings, edit_settings, edit_version, roots, sidecars, lr ids)")
        check(after.members == before.members, "all \(after.members.count) folder memberships identical (incl. sort order)")
        check(after.folders == before.folders && after.roots == before.roots, "folders (\(after.folders)) / roots (\(after.roots)) unchanged")
        let edited = try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE edit_settings IS NOT NULL") ?? 0
        let picked = try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE flag = 1") ?? 0
        print("  after: \(edited) edited, \(picked) picked")
        try schemaChecks(catalog, "realistic")
        // A realistic query still works and copies sort next to their master there too.
        if let vineyards = try catalog.allFolders().first(where: { $0.name == "Vineyards" }) {
            let photos = try catalog.photos(in: .folder(id: vineyards.id, includeSubfolders: false))
            let targets = Array(photos.prefix(3).map(\.id))
            let made = try time("create 3 virtual copies in a 21k catalog") { try catalog.createVirtualCopies(of: targets, inFolder: vineyards.id) }
            let listed = try time("Vineyards query with copies") { try catalog.photos(in: .folder(id: vineyards.id, includeSubfolders: false)) }
            check(listed.count == photos.count + 3, "Vineyards lists \(photos.count) + 3 copies")
            let ok = made.allSatisfy { m in
                guard let i = listed.firstIndex(where: { $0.id == m.masterID }) else { return false }
                return listed[i + 1].id == m.id
            }
            check(ok, "each copy right after its master in Vineyards")
            _ = try time("All Photographs query (\(try catalog.totalPhotoCount()) rows)") { try catalog.photos(in: .all) }
        }
        catalog.close()
    }

    // MARK: - Creating copies

    static func copies(_ dir: URL) throws {
        print("Creating virtual copies")
        let catalog = try Catalog.open(at: dir)
        let root = try catalog.upsertRoot(path: "/vc/photos", bookmark: nil)
        var a = photo("IMG_0001.DNG", day: 1); a.sidecarPath = "/vc/photos/IMG_0001.JPG"; a.lrImageID = 77
        let ids = try catalog.insertPhotos([a, photo("IMG_0002.DNG", day: 2), photo("IMG_0003.DNG", day: 3)])
        let (p1, p2, p3) = (ids[0], ids[1], ids[2])
        let crop = NormRect(x: 0.1, y: 0.05, width: 0.6, height: 0.9)
        try catalog.saveEditSettings(editedSettings(exposure: 1.0, crop: crop), for: p1)
        try catalog.saveEditSettings(editedSettings(exposure: 1.0, crop: crop), for: p1)   // edit_version 2
        try catalog.setFlag(.pick, for: [p1])
        try catalog.setRating(3, for: [p1])
        let stories = try catalog.createFolder(name: "Instagram Stories")
        let trip = try catalog.createFolder(name: "Trip")
        try catalog.addPhotos([p1, p2], toFolder: trip)
        let master = try catalog.photo(id: p1)!

        let c1 = try catalog.createVirtualCopies(of: [p1], inFolder: stories)[0]
        let copy1 = try catalog.photo(id: c1.id)!
        check(copy1.masterID == p1 && copy1.copyName == "Copy 1" && c1.sourceID == p1, "copy 1: master_id = master, \"Copy 1\"")
        check(copy1.path == master.path && copy1.rootID == root && copy1.sidecarPath == master.sidecarPath
              && copy1.fileName == master.fileName && copy1.captureDate == master.captureDate && copy1.importDate == master.importDate
              && copy1.width == master.width, "same file, root, sidecar, metadata, import date")
        check(copy1.editSettingsJSON == master.editSettingsJSON && copy1.editVersion == master.editVersion && copy1.editVersion == 2,
              "starts with the master's edit settings and edit version")
        check(copy1.flag == .pick && copy1.rating == 3, "flag + rating copied")
        check(copy1.lrImageID == nil, "no Lightroom image id on the copy")
        check(try catalog.folderIDs(containing: c1.id) == [stories], "copy is only in the target folder (not the master's folders)")
        check(try catalog.folderIDs(containing: p1) == [trip], "master's folders unchanged")
        check(copy1.displayTitle == "IMG_0001 · Copy 1", "title \"IMG_0001 · Copy 1\"")
        check(copy1.virtualCopyDescription == "Virtual copy of IMG_0001.DNG (Copy 1)", "tooltip text")
        check(copy1.exportBaseName == "IMG_0001 (Copy 1)" && master.exportBaseName == "IMG_0001", "export base names")

        let c2 = try catalog.createVirtualCopies(of: [c1.id])[0]
        check(try c2.masterID == p1 && catalog.photo(id: c2.id)?.masterID == p1, "copy of a copy → copy of the same master")
        check(c2.copyName == "Copy 2", "numbering continues: Copy 2")
        check(try catalog.folderIDs(containing: c2.id).isEmpty, "no folder when none is given")

        // Independent afterwards.
        try catalog.saveEditSettings(editedSettings(exposure: -1.5, crop: NormRect(x: 0.3, y: 0, width: 0.3375, height: 1)), for: c1.id)
        try catalog.setFlag(.reject, for: [c1.id])
        try catalog.setRating(5, for: [c1.id])
        let m2 = try catalog.photo(id: p1)!, cc1 = try catalog.photo(id: c1.id)!, cc2 = try catalog.photo(id: c2.id)!
        check(m2.editSettings.tone.exposure == 1.0 && m2.editSettings.geometry.crop == crop && m2.editVersion == 2, "editing the copy leaves the master's edits alone")
        check(cc2.editSettings.tone.exposure == 1.0 && cc2.editSettings.geometry.crop == crop, "… and the other copy's")
        check(cc1.editSettings.tone.exposure == -1.5 && cc1.editVersion == 3, "copy has its own edits / edit version")
        check(m2.flag == .pick && m2.rating == 3 && cc1.flag == .reject && cc1.rating == 5, "flags / ratings independent")

        // Numbering: never reused while it exists; rename.
        try catalog.removePhotos(ids: [c2.id])
        let c3 = try catalog.createVirtualCopies(of: [p1])[0]
        check(c3.copyName == "Copy 2", "Copy 2 removed → the next copy is Copy 2 again (Copy 1 still exists)")
        try catalog.renameVirtualCopy(id: c1.id, to: "  Story ")
        let renamed = try catalog.photo(id: c1.id)!
        check(renamed.copyName == "Story" && renamed.displayTitle == "IMG_0001 · Story" && renamed.exportBaseName == "IMG_0001 (Story)", "rename → \"Story\" in titles / export names")
        check(try catalog.createVirtualCopies(of: [p1])[0].copyName == "Copy 3", "after renaming Copy 1, numbers continue from Copy 2 → Copy 3")
        var threw = false
        do { try catalog.renameVirtualCopy(id: p1, to: "X") } catch { threw = true }
        check(threw, "renaming a master is refused")
        threw = false
        do { try catalog.renameVirtualCopy(id: c1.id, to: "  ") } catch { threw = true }
        check(threw, "empty names are refused")

        // Initial settings seam (e.g. a per-folder default crop later).
        let seam = try catalog.createVirtualCopies(of: [p2], inFolder: stories) { source in
            var s = source.editSettings
            s.geometry.crop = NormRect(x: 0.25, y: 0, width: 0.5, height: 1)
            return s
        }[0]
        let seamPhoto = try catalog.photo(id: seam.id)!
        check(seamPhoto.editSettings.geometry.crop.width == 0.5 && seamPhoto.editVersion == 1, "initialSettings applied (edit version bumped past the source's)")

        // Sorting: copies right after their master under every sort.
        let copiesOfP1 = try catalog.virtualCopyIDs(ofMasters: [p1])
        for key in PhotoSort.Key.allCases {
            for asc in [true, false] {
                let list = try catalog.photos(in: .all, sort: PhotoSort(key: key, ascending: asc)).map(\.id)
                guard let i = list.firstIndex(of: p1), let j = list.firstIndex(of: p2) else { check(false, "sort \(key)"); continue }
                let ok = Array(list[(i + 1)...].prefix(copiesOfP1.count)) == copiesOfP1 && list[j + 1] == seam.id
                check(ok, "sort \(key.rawValue) \(asc ? "asc" : "desc"): copies right after their master, by copy number (\(list))")
            }
        }
        // Folder order: master first in Trip; copy appended to Stories lists after its master when both are there.
        try catalog.addPhotos([p3, p1], toFolder: stories)
        let storiesOrder = try catalog.photos(in: .folder(id: stories, includeSubfolders: false), sort: PhotoSort(key: .folderOrder)).map(\.id)
        // Stories: c1 (order 0), seam copy (1), p3 (2), p1 (3) → c1 moves after p1; the seam copy's master isn't there.
        check(storiesOrder == [seam.id, p3, p1, c1.id], "folder order: copy follows its master even when added to the folder before it (\(storiesOrder))")
        let picked = try catalog.photos(in: .all, filter: PhotoFilter(flag: .rejected)).map(\.id)
        check(picked == [c1.id], "filters see the copy's own flag (Rejected lists only the copy)")
        check(try catalog.photos(in: .lastImport).count == (try catalog.totalPhotoCount()), "copies keep the import date (Previous Import unchanged)")
        check(try catalog.virtualCopyCount() == 4, "4 virtual copies")
        catalog.close()
    }

    // MARK: - Path dedupe of imports

    static func imports(_ dir: URL) throws {
        print("Imports dedupe by master path")
        let catalog = try Catalog.open(at: dir)
        let ids = try catalog.insertPhotos([photo("L1.DNG", dir: "/Volumes/X/LR"), photo("L2.DNG", dir: "/Volumes/X/LR")])
        let copies = try catalog.createVirtualCopies(of: [ids[0], ids[0]])
        check(copies.count == 2, "two copies of L1")
        check(try catalog.insertPhotos([photo("L1.DNG", dir: "/Volumes/X/LR")]) == [ids[0]], "insertPhotos of a copied path returns the master id")
        check(try catalog.photoID(path: "/Volumes/X/LR/L1.DNG") == ids[0], "photoID(path:) finds the master, not a copy")
        check(try catalog.importFingerprints().count == 2, "SD import fingerprints: masters only")
        check(try catalog.totalPhotoCount() == 4, "nothing inserted twice")

        // Lightroom import (collections-only behaviour unchanged): existing path → the master.
        let snapshot = LightroomCatalogSnapshot(
            catalogName: "Test.lrcat",
            roots: [LRRootFolder(id: 1, path: "/Volumes/X/LR", name: "LR")],
            images: [LRImage(id: 501, rootFolderID: 1, path: "/Volumes/X/LR/L1.DNG", fileName: "L1.DNG", captureDate: nil, pick: 1, rating: 4),
                     LRImage(id: 502, rootFolderID: 1, path: "/Volumes/X/LR/L3.DNG", fileName: "L3.DNG", captureDate: nil),
                     LRImage(id: 503, rootFolderID: 1, path: "/Volumes/X/LR/L1.DNG", fileName: "L1.DNG", captureDate: nil, masterID: 501)],
            collections: [LRCollection(id: 900, name: "Best", parentID: nil, kind: .collection, imageIDs: [501, 503, 502])])
        let plan = LightroomImportPlan(snapshot: snapshot, options: LightroomImportOptions())
        let result = try catalog.importLightroom(plan)
        check(result.photosExisting == 1 && result.photosAdded == 1, "LR import: L1 matched (existing), L3 added (\(result.photosAdded) added, \(result.photosExisting) existing)")
        let l1 = try catalog.photo(id: ids[0])!
        check(l1.lrImageID == 501 && l1.flag == .pick && l1.rating == 4, "LR data merged into the master")
        check(try copies.allSatisfy { try catalog.photo(id: $0.id)?.lrImageID == nil && catalog.photo(id: $0.id)?.flag == Flag.none },
              "copies untouched by the LR import")
        let best = try catalog.allFolders().first { $0.name == "Best" }!
        let members = try catalog.photos(in: .folder(id: best.id, includeSubfolders: false), sort: PhotoSort(key: .folderOrder)).map(\.id)
        check(members.count == 2 && members.first == ids[0], "LR collection holds the master (LR virtual copy → master), not our copies")
        let again = try catalog.importLightroom(plan)
        check(again.photosAdded == 0, "LR re-import adds nothing")
        catalog.close()
    }

    // MARK: - Relink

    static func relink(_ dir: URL) throws {
        print("Relink rewrites virtual copies")
        let catalog = try Catalog.open(at: dir)
        let rootID = try catalog.upsertRoot(path: "/Volumes/Old/Photos", bookmark: nil)
        var a = photo("R1.DNG", dir: "/Volumes/Old/Photos/2026"); a.sidecarPath = "/Volumes/Old/Photos/2026/R1.JPG"
        let ids = try catalog.insertPhotos([a, photo("R2.DNG", dir: "/Volumes/Old/Photos/2026")])
        let made = try catalog.createVirtualCopies(of: [ids[0], ids[0], ids[1]])
        let root = try catalog.root(id: rootID)!
        let checkResult = try catalog.relinkCheck(root: root, newPath: "/Volumes/New/Photos") { _ in true }
        check(checkResult.photoCount == 2, "relink check counts files (masters), not copies (\(checkResult.photoCount))")
        let r = try catalog.relinkRoot(id: rootID, to: "/Volumes/New/Photos", bookmark: nil)
        check(r.photoIDs.count == 5, "relink rewrote 2 masters + 3 copies")
        let all = try catalog.photos(in: .all)
        check(all.allSatisfy { $0.path.hasPrefix("/Volumes/New/Photos/2026/") && $0.rootID == rootID }, "every row (copies too) has the new path + root")
        check(try made.allSatisfy { try catalog.photo(id: $0.id)?.path == catalog.photo(id: $0.masterID)?.path }, "copies share their master's new path")
        check(try catalog.photo(id: made[0].id)?.sidecarPath == "/Volumes/New/Photos/2026/R1.JPG", "copy sidecar rewritten")
        check(try catalog.photoID(path: "/Volumes/New/Photos/2026/R1.DNG") == ids[0], "master found at the new path")
        catalog.close()
    }

    // MARK: - Removal

    static func removal(_ dir: URL) throws {
        print("Removal")
        let catalog = try Catalog.open(at: dir)
        let ids = try catalog.insertPhotos([photo("X1.DNG"), photo("X2.DNG")])
        let folder = try catalog.createFolder(name: "Posts")
        let made = try catalog.createVirtualCopies(of: [ids[0], ids[0], ids[1]], inFolder: folder)
        check(try catalog.cascadedVirtualCopyCount(removing: [ids[0]]) == 2, "removing X1 would remove its 2 copies")
        check(try catalog.cascadedVirtualCopyCount(removing: [ids[0], made[0].id]) == 1, "… 1 more when one copy is itself selected")
        check(try catalog.idsIncludingVirtualCopies([ids[0]]) == [ids[0], made[0].id, made[1].id], "ids incl. cascaded copies")
        try catalog.removePhotos(ids: [made[2].id])
        check(try catalog.photo(id: ids[1]) != nil && catalog.photo(id: made[2].id) == nil, "removing a copy removes only the copy")
        try catalog.removePhotos(ids: [ids[0]])
        check(try catalog.photo(id: made[0].id) == nil && catalog.photo(id: made[1].id) == nil, "removing a master removes its copies")
        check(try catalog.photoCount(folderID: folder) == 0, "their folder memberships are gone")
        check(try catalog.totalPhotoCount() == 1, "only X2 left")
        catalog.close()
    }

    // MARK: - Previews

    static func previews(_ dir: URL) throws {
        print("Preview seeding")
        let catalog = try Catalog.open(at: dir)
        let disk = PreviewDiskCache(directory: dir.appendingPathComponent("Previews"))
        let ids = try catalog.insertPhotos([photo("P1.DNG")])
        try catalog.saveEditSettings(editedSettings(exposure: 0.5), for: ids[0])
        let master = try catalog.photo(id: ids[0])!
        let image = solidImage()
        let names = ["\(ids[0])_t_v\(master.editVersion)_512q80e.jpg", "\(ids[0])_s_v\(master.editVersion)_2048q85r.jpg"]
        check(disk.write(image, photoID: ids[0], level: .thumbnail, name: names[0], quality: 0.8)
              && disk.write(image, photoID: ids[0], level: .standard, name: names[1], quality: 0.8), "master previews written")
        let recentDir = dir.appendingPathComponent("Previews/Recent")
        let recent = RecentRenders()
        recent.configure(directory: recentDir, limit: 10)
        let hash = RecentRenderKey.settingsHash(master.editSettings)
        recent.store(image, key: RecentRenderKey(photoID: ids[0], settingsHash: hash, box: CGSize(width: 64, height: 48)))

        let made = try catalog.createVirtualCopies(of: [ids[0]])
        let t = Date()
        VirtualCopyPreviews.seed(made, catalog: catalog, disk: disk, recent: recent)
        print(String(format: "  seed 1 copy: %.2f ms", Date().timeIntervalSince(t) * 1000))
        let copyID = made[0].id
        let copyNames = names.map { "\(copyID)_" + $0.dropFirst("\(ids[0])_".count) }
        check(copyNames.allSatisfy { disk.exists(photoID: copyID, name: $0) }, "copy's thumbnail + standard previews exist under its own key (\(copyNames))")
        check(disk.read(photoID: copyID, name: copyNames[0]) != nil, "seeded preview decodes")
        check(recent.memoryRender(photoID: copyID, settingsHash: hash) != nil, "recent Develop render seeded for the copy")
        // After the copy is edited its key changes: the seeded files no longer match.
        try catalog.saveEditSettings(editedSettings(exposure: -2), for: copyID)
        let edited = try catalog.photo(id: copyID)!
        check(!disk.exists(photoID: copyID, name: "\(copyID)_t_v\(edited.editVersion)_512q80e.jpg"), "an edited copy needs a new preview (edit version in the key)")
        disk.remove(photoIDs: [copyID])
        check(!copyNames.contains { disk.exists(photoID: copyID, name: $0) } && names.allSatisfy { disk.exists(photoID: ids[0], name: $0) },
              "removing the copy's previews keeps the master's")
        recent.flush()
        recent.remove(photoIDs: [copyID])
        check(recent.memoryRender(photoID: copyID, settingsHash: hash) == nil && recent.memoryRender(photoID: ids[0], settingsHash: hash) != nil,
              "recent render removed for the copy only")
        catalog.close()
    }

    static func solidImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return ctx.makeImage()!
    }

    // MARK: - Export names

    static func export(_ dir: URL, sample: URL) throws {
        print("Export file names")
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: sample.path) else { print("  SKIP (no sample \(sample.path))"); return }
        try fm.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        let local = dir.appendingPathComponent("photos/\(sample.lastPathComponent)")
        try fm.copyItem(at: sample, to: local)   // COPY, the sample stays untouched
        let catalog = try Catalog.open(at: dir.appendingPathComponent("cat"))
        guard let meta = PhotoMetadataReader.read(url: local) else { check(false, "sample metadata"); return }
        let master = try catalog.insertPhoto(Photo(url: local, metadata: meta))
        let made = try catalog.createVirtualCopies(of: [master, master])
        try catalog.renameVirtualCopy(id: made[1].id, to: "Story")
        try catalog.saveEditSettings(editedSettings(exposure: 0, crop: NormRect(x: 0.3, y: 0, width: 0.28, height: 1)), for: made[0].id)
        let dest = dir.appendingPathComponent("out")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let ids = [master, made[0].id, made[1].id]
        let base = local.deletingPathExtension().lastPathComponent
        let first = time("export master + 2 copies") { ExportJob(catalog: catalog, photoIDs: ids, options: ExportOptions(destination: dest, quality: 60)).run() }
        let names1 = Set(first.exported.map(\.url.lastPathComponent))
        check(names1 == ["\(base).jpg", "\(base) (Copy 1).jpg", "\(base) (Story).jpg"], "names: \(names1.sorted())")
        let byID = Dictionary(first.exported.map { ($0.photoID, $0) }, uniquingKeysWith: { a, _ in a })
        if let m = byID[master], let c = byID[made[0].id] {
            check(c.pixelWidth < m.pixelWidth / 2, "the copy's own crop is exported (\(c.pixelWidth)×\(c.pixelHeight) vs \(m.pixelWidth)×\(m.pixelHeight))")
        }
        let second = ExportJob(catalog: catalog, photoIDs: ids, options: ExportOptions(destination: dest, quality: 60)).run()
        let names2 = Set(second.exported.map(\.url.lastPathComponent))
        check(names2 == ["\(base)-1.jpg", "\(base) (Copy 1)-1.jpg", "\(base) (Story)-1.jpg"], "existing names still get -1: \(names2.sorted())")
        catalog.close()
    }
}
