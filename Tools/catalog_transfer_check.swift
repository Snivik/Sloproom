//
//  catalog_transfer_check.swift
//  Headless check of Export Catalog / Import Catalog (replace + backup) / Relink.
//
//  Tools/harness.sh /private/tmp/claude-501/catalog-out/catalog_transfer_check Tools/catalog_transfer_check.swift \
//    sloproom/CatalogTransfer/CatalogTransfer.swift \
//    sloproom/LightroomImport/RootAccess.swift
//  /private/tmp/claude-501/catalog-out/catalog_transfer_check <catalog-dir-to-COPY> [out-dir]
//
//  <catalog-dir-to-COPY> holds a Catalog.sqlite (+ -wal/-shm) — e.g. a COPY of the realistic live
//  catalog. It is copied into out-dir first and never opened in place. Nothing outside out-dir is
//  written; photo files are only stat-ed (relink sampling).
//

import Foundation

@main
struct CatalogTransferCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let source = URL(fileURLWithPath: args.count > 1 ? args[1]
                         : home + "/Library/Containers/dev.snivik.sloproom/Data/tmp/catalog/pristine", isDirectory: true)
        let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/catalog-out/run", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        // MARK: Live catalog (copy)
        print("== live catalog copy from \(source.path)")
        let liveDir = out.appendingPathComponent("live", isDirectory: true)
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: source.path + "/Catalog.sqlite" + suffix) {
            try fm.copyItem(atPath: source.path + "/Catalog.sqlite" + suffix, toPath: liveDir.path + "/Catalog.sqlite" + suffix)
        }
        let live = try Catalog.open(at: liveDir)
        let base = try CatalogTransfer.info(of: live)
        let baseDigest = try digest(live)
        print("  \(base.photoCount) photos, \(base.editedPhotoCount) edited, \(base.pickedCount) picked, \(base.folderCount) folders, \(base.folderMembershipCount) memberships, \(base.rootCount) roots, schema \(base.schemaVersion)")
        check(base.photoCount > 0, "live catalog has photos")

        // MARK: Export while open (and while another thread writes)
        print("== export")
        let exports = out.appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        let exportURL = exports.appendingPathComponent(CatalogTransfer.defaultExportName())
        check(exportURL.lastPathComponent.hasPrefix("Sloproom Catalog 20") && exportURL.pathExtension == "sloproomcatalog",
              "default name \(exportURL.lastPathComponent)")
        let someID = try live.db.scalarInt("SELECT id FROM photos ORDER BY id LIMIT 1") ?? 0
        let someRating = try live.photo(id: someID)?.rating ?? 0
        let writer = Task.detached {   // concurrent write transactions while the snapshot runs
            for _ in 0..<200 { try? live.setRating(someRating, for: [someID]) }
        }
        let exported = try CatalogTransfer.exportCatalog(live, to: exportURL, appVersion: "1.0", appBuild: "1", sourceMac: "Harness Mac")
        await writer.value
        print(String(format: "  exported %.1f MB in %.3f s via %@", Double(exported.bytes) / 1e6, exported.seconds, exported.writeMethod))
        check(fm.fileExists(atPath: exportURL.path), "export file exists")
        check(!fm.fileExists(atPath: exportURL.path + "-wal") && !fm.fileExists(atPath: exportURL.path + "-journal"), "export is a single file")
        check(headerByte18(exportURL) == 1, "export uses a rollback journal (self-contained)")
        let leftovers = (try? fm.contentsOfDirectory(atPath: CatalogTransfer.workDirectory(for: live).path)) ?? []
        check(leftovers.isEmpty, "no temp files left in Transfer/ (\(leftovers))")
        check(exported.info.photoCount == base.photoCount && exported.info.folderCount == base.folderCount
              && exported.info.editedPhotoCount == base.editedPhotoCount, "export counts equal live")

        // Validate a COPY (validate converts journal mode; must not touch the export)
        let probe = out.appendingPathComponent("probe.sqlite")
        try fm.copyItem(at: exportURL, to: probe)
        let (vinfo, vroots) = try CatalogTransfer.validate(databaseAt: probe)
        check(vinfo.formatVersion == CatalogTransfer.formatVersion, "catalog_info.format_version = \(vinfo.formatVersion ?? -1)")
        check(vinfo.sourceMac == "Harness Mac" && vinfo.appVersion == "1.0" && vinfo.exportedAt != nil, "catalog_info source mac / app version / exported_at")
        check(vinfo.schemaVersion == Catalog.schemaVersion, "schema version \(vinfo.schemaVersion)")
        check(vinfo.photoCount == base.photoCount && vinfo.folderMembershipCount == base.folderMembershipCount
              && vinfo.pickedCount == base.pickedCount && vinfo.rootCount == base.rootCount, "snapshot counts equal (integrity ok)")
        check(vroots.count == base.rootCount, "roots listed")
        let snapDigest = try digest(Catalog.open(at: probeDir(probe, out)))
        check(snapDigest == baseDigest, "snapshot rows equal live rows (flags, ratings, edits, folders, memberships)")
        check(!(try tableNames(live)).contains("catalog_info"), "live catalog untouched (no catalog_info)")

        // Overwrite an existing export
        let again = try CatalogTransfer.exportCatalog(live, to: exportURL, appVersion: "1.0", appBuild: "2", sourceMac: "Harness Mac")
        check(again.info.photoCount == base.photoCount && fm.fileExists(atPath: exportURL.path), "re-export over existing file (\(again.writeMethod))")

        // MARK: Refusals
        print("== refusals")
        let newer = out.appendingPathComponent("newer.sloproomcatalog")
        try fm.copyItem(at: exportURL, to: newer)
        try setPragma(newer, "PRAGMA user_version = \(Catalog.schemaVersion + 1)")
        expectError(try CatalogTransfer.stageImport(from: newer, stagingDirectory: out.appendingPathComponent("stage-x"))) {
            if case .newerSchema(let f, let s) = $0 { return f == Catalog.schemaVersion + 1 && s == Catalog.schemaVersion }; return false
        }
        let newerFormat = out.appendingPathComponent("newerformat.sloproomcatalog")
        try fm.copyItem(at: exportURL, to: newerFormat)
        try setPragma(newerFormat, "UPDATE catalog_info SET value = '99' WHERE key = 'format_version'")
        expectError(try CatalogTransfer.stageImport(from: newerFormat, stagingDirectory: out.appendingPathComponent("stage-x"))) {
            if case .newerFormat = $0 { return true }; return false
        }
        let text = out.appendingPathComponent("notes.sloproomcatalog")
        try Data("hello, not a database at all — just some text padding it out".utf8).write(to: text)
        expectError(try CatalogTransfer.stageImport(from: text, stagingDirectory: out.appendingPathComponent("stage-x"))) {
            if case .notACatalog = $0 { return true }; return false
        }
        let otherDB = out.appendingPathComponent("other.sqlite")
        try setPragma(otherDB, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)")
        expectError(try CatalogTransfer.stageImport(from: otherDB, stagingDirectory: out.appendingPathComponent("stage-x"))) {
            if case .notACatalog = $0 { return true }; return false
        }
        let stageLeft = (try? fm.contentsOfDirectory(atPath: out.appendingPathComponent("stage-x").path)) ?? []
        check(stageLeft.isEmpty, "refused files leave no staged copies (\(stageLeft))")

        // MARK: Import as replacement into a temp app-support dir
        print("== import (replace)")
        let appSupport = out.appendingPathComponent("AppSupport/Sloproom", isDirectory: true)
        let current = try Catalog.open(at: appSupport)
        let cp = try current.insertPhotos([Photo(path: "/tmp/cur/a.jpg"), Photo(path: "/tmp/cur/b.jpg"), Photo(path: "/tmp/cur/c.jpg")])
        let cf = try current.createFolder(name: "Current Only")
        try current.addPhotos(cp, toFolder: cf)
        try current.setFlag(.pick, for: [cp[0]])
        // Previews dir with a file (must be discarded on import).
        let prev = current.cacheDirectory("Previews").appendingPathComponent("01")
        try fm.createDirectory(at: prev, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: prev.appendingPathComponent("1_t_v0_x.jpg"))

        let t0 = Date()
        let candidate = try CatalogTransfer.stageImport(from: exportURL, stagingDirectory: CatalogTransfer.workDirectory(for: current))
        print(String(format: "  staged + validated in %.3f s", Date().timeIntervalSince(t0)))
        check(candidate.info.photoCount == base.photoCount && candidate.info.isExport && !candidate.needsMigration, "candidate summary counts")
        check(candidate.roots.count == base.rootCount, "candidate roots \(candidate.roots.map(\.path))")
        for r in candidate.roots { print("    root \(r.path): \(RootAccess.status(of: r).title)") }
        let t1 = Date()
        let (imported, backup) = try CatalogTransfer.replaceCatalog(current, with: candidate)
        CatalogTransfer.discardPreviewsDirectory(in: appSupport, synchronously: true)
        print(String(format: "  replaced in %.3f s; backup %@", Date().timeIntervalSince(t1), backup.lastPathComponent))
        check((try? current.totalPhotoCount()) == nil, "old catalog instance is closed (calls throw)")
        let ii = try CatalogTransfer.info(of: imported)
        check(ii.photoCount == base.photoCount && ii.folderCount == base.folderCount && ii.editedPhotoCount == base.editedPhotoCount
              && ii.pickedCount == base.pickedCount, "imported counts equal source")
        check(try digest(imported) == baseDigest, "imported rows equal source rows")
        check(backup.deletingLastPathComponent().path == appSupport.appendingPathComponent("Backups").path
              && backup.lastPathComponent.range(of: #"^Catalog-\d{8}-\d{6}\.sqlite$"#, options: .regularExpression) != nil,
              "backup at Backups/\(backup.lastPathComponent)")
        let backupProbe = out.appendingPathComponent("backup-probe.sqlite")
        try fm.copyItem(at: backup, to: backupProbe)
        let (binfo, _) = try CatalogTransfer.validate(databaseAt: backupProbe)
        check(binfo.photoCount == 3 && binfo.folderCount == 1 && binfo.pickedCount == 1, "backup holds the previous catalog (3 photos, 1 folder)")
        check(!fm.fileExists(atPath: prev.path), "Previews directory discarded")
        check(!fm.fileExists(atPath: candidate.stagedURL.path), "staged file consumed")
        let dirFiles = try fm.contentsOfDirectory(atPath: appSupport.path).sorted()
        print("    app support now: \(dirFiles)")
        // New catalog is fully usable (writes + migrations).
        try imported.setFlag(.reject, for: [someID])
        check(try imported.photo(id: someID)?.flag == .reject, "imported catalog writable")
        try imported.setFlag(.none, for: [someID])

        // Backups keep the last 10
        for i in 0..<12 {
            _ = try CatalogTransfer.backupCatalog(imported, into: CatalogTransfer.backupsDirectory(for: imported),
                                                  date: Date(timeIntervalSince1970: 1_600_000_000 + Double(i)))
        }
        let kept = CatalogTransfer.backups(in: CatalogTransfer.backupsDirectory(for: imported))
        check(kept.count == 10, "backups pruned to 10 (have \(kept.count))")
        check(kept.contains(backup), "newest backup kept, oldest removed first")
        let justMade = try CatalogTransfer.backupCatalog(imported, into: CatalogTransfer.backupsDirectory(for: imported),
                                                         date: Date(timeIntervalSince1970: 1_500_000_000))
        check(FileManager.default.fileExists(atPath: justMade.path) && CatalogTransfer.backups(in: justMade.deletingLastPathComponent()).count == 10,
              "a backup is never pruned right after it is written")

        // Failure after close → previous catalog restored
        print("== failed replace restores")
        let before = try CatalogTransfer.info(of: imported)
        var broken = try CatalogTransfer.stageImport(from: exportURL, stagingDirectory: CatalogTransfer.workDirectory(for: imported))
        try fm.removeItem(at: broken.stagedURL)   // install will fail
        broken.stagedURL = broken.stagedURL.appendingPathExtension("missing")
        var restored: Catalog?
        do {
            _ = try CatalogTransfer.replaceCatalog(imported, with: broken)
            check(false, "replace with a missing staged file should fail")
        } catch let CatalogTransferError.replaceFailed(why, _, reopened) {
            print("    failed as expected: \(why.prefix(80))")
            restored = reopened
        }
        check(restored != nil && (try? CatalogTransfer.info(of: restored!))?.photoCount == before.photoCount, "previous catalog reopened after failure")
        let cat = restored ?? imported

        // MARK: Relink (on the imported COPY)
        print("== relink")
        guard let t9 = try cat.allRoots().first(where: { $0.path.hasSuffix("/Lightroom") && $0.path.contains("T9") }) ?? cat.allRoots().first else {
            check(false, "catalog has a root to relink"); return finish()
        }
        let digestBefore = try digest(cat)
        let t9Photos = try cat.photoPaths(of: t9)
        let total = try cat.totalPhotoCount()
        print("  root \(t9.path): \(t9Photos.count) photos")
        let sameCheck = try cat.relinkCheck(root: t9, newPath: t9.path)
        print("  check at its own path: \(sameCheck.found)/\(sameCheck.sampled) found (drive \(RootAccess.isOnline(t9.path) ? "online" : "offline"))")
        let fake = out.appendingPathComponent("Fake T9/Lightroom").path
        let fakeCheck = try cat.relinkCheck(root: t9, newPath: fake)
        check(fakeCheck.sampled == min(200, t9Photos.count) && fakeCheck.found == 0 && !fakeCheck.looksRight, "sample at a fake path: 0/\(fakeCheck.sampled) → warn")
        // A partial copy of the layout at the fake path: 90% of the sample found → looks right
        let sampleFake = try cat.relinkCheck(root: t9, newPath: fake, fileExists: { !$0.hasSuffix("0.DNG") })
        print("  simulated partial layout: \(sampleFake.found)/\(sampleFake.sampled) (\(Int(sampleFake.fraction * 100))%) looksRight=\(sampleFake.looksRight)")
        let otherRootPhotos = try cat.allRoots().filter { $0.id != t9.id }.flatMap { try cat.photoPaths(of: $0).map(\.path) }.sorted()
        let t2 = Date()
        let r1 = try RootAccess.relink(t9, to: URL(fileURLWithPath: fake, isDirectory: true), bookmark: nil, catalog: cat)
        print(String(format: "  relinked %d photos (%d sidecars) in %.3f s", r1.photoIDs.count, r1.sidecarsRewritten, Date().timeIntervalSince(t2)))
        let moved = try cat.photos(ids: r1.photoIDs)
        check(r1.photoIDs.count == t9Photos.count && moved.allSatisfy { $0.path.hasPrefix(Catalog.normalizedPath(fake) + "/") }, "all root photos rewritten to the new prefix")
        check(moved.allSatisfy { $0.sidecarPath.map { $0.hasPrefix(Catalog.normalizedPath(fake) + "/") } ?? true }, "sidecar paths rewritten")
        check(moved.allSatisfy { $0.rootID == t9.id }, "photos keep root id")
        check(try cat.root(id: t9.id)?.path == Catalog.normalizedPath(fake), "root path updated")
        check(try cat.totalPhotoCount() == total, "photo count unchanged")
        let otherAfter = try cat.allRoots().filter { $0.id != t9.id }.flatMap { try cat.photoPaths(of: $0).map(\.path) }.sorted()
        check(otherAfter == otherRootPhotos, "other roots' photos untouched")
        check(try cat.root(for: moved[0].path)?.id == t9.id, "moved photos resolve to the relinked root")
        // Relink into an existing root's path is refused
        if let other = try cat.allRoots().first(where: { $0.id != t9.id }) {
            expectRelinkError(try cat.relinkRoot(id: t9.id, to: other.path, bookmark: nil)) {
                if case .pathInUse = $0 { return true }; return false
            }
        }
        // and back
        let back = try cat.root(id: t9.id)!
        _ = try RootAccess.relink(back, to: URL(fileURLWithPath: t9.path, isDirectory: true), bookmark: t9.bookmark, catalog: cat)
        check(try digest(cat) == digestBefore, "relink back restores every path (rows identical)")
        check(try cat.root(id: t9.id)?.path == t9.path && (try cat.root(id: t9.id)?.bookmark) == t9.bookmark, "root path + bookmark restored")
        check(try cat.totalPhotoCount() == total, "photo count unchanged after round trip")
        // Paths of a root at "/" and nested prefixes
        check(Catalog.relinkedPath("/Volumes/T9/Lightroom/2020/a.dng", from: "/Volumes/T9/Lightroom", to: "/Volumes/T9 Old/LR") == "/Volumes/T9 Old/LR/2020/a.dng", "relinkedPath")
        check(Catalog.relinkedPath("/private/tmp/x/a.dng", from: "/tmp/x", to: "/tmp/x/y") == "/tmp/x/y/a.dng", "relinkedPath normalizes /private")
        finish()
    }

    static func finish() {
        print(failures == 0 ? "ALL CATALOG TRANSFER CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Helpers

    /// Opens a copied database file as a catalog in its own directory.
    static func probeDir(_ file: URL, _ out: URL) throws -> URL {
        let dir = out.appendingPathComponent("probe-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("Catalog.sqlite"))
        return dir
    }

    /// Order-independent fingerprint of everything the user cares about.
    static func digest(_ c: Catalog) throws -> [String] {
        var rows = try c.db.query("SELECT id, path, IFNULL(sidecar_path,''), flag, rating, IFNULL(edit_settings,''), edit_version, IFNULL(root_id,0) FROM photos ORDER BY id") {
            "p\($0.int(0))|\($0.string(1))|\($0.string(2))|\($0.int(3))|\($0.int(4))|\($0.string(5).hashValue)|\($0.int(6))|\($0.int(7))"
        }
        rows += try c.db.query("SELECT id, IFNULL(parent_id,0), name, sort_order FROM folders ORDER BY id") { "f\($0.int(0))|\($0.int(1))|\($0.string(2))|\($0.int(3))" }
        rows += try c.db.query("SELECT folder_id, photo_id, sort_order FROM folder_photos ORDER BY folder_id, photo_id") { "m\($0.int(0))|\($0.int(1))|\($0.int(2))" }
        rows += try c.db.query("SELECT id, path FROM roots ORDER BY id") { "r\($0.int(0))|\($0.string(1))" }
        return rows
    }

    static func tableNames(_ c: Catalog) throws -> Set<String> {
        Set(try c.db.query("SELECT name FROM sqlite_master WHERE type='table'") { $0.string(0) })
    }

    static func setPragma(_ url: URL, _ sql: String) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute(sql)
        try db.execute("PRAGMA journal_mode=DELETE")
        db.close()
    }

    static func headerByte18(_ url: URL) -> UInt8 {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 20), d.count == 20 else { return 0 }
        return d[18]
    }

    static func expectError<T>(_ body: @autoclosure () throws -> T, _ matches: (CatalogTransferError) -> Bool) {
        do {
            _ = try body()
            check(false, "expected an error")
        } catch let e as CatalogTransferError {
            check(matches(e), "refused: \(e.description.prefix(110))")
        } catch {
            check(false, "unexpected error \(error)")
        }
    }

    static func expectRelinkError<T>(_ body: @autoclosure () throws -> T, _ matches: (RelinkError) -> Bool) {
        do {
            _ = try body()
            check(false, "expected a relink error")
        } catch let e as RelinkError {
            check(matches(e), "relink refused: \(e.description.prefix(100))")
        } catch {
            check(false, "unexpected error \(error)")
        }
    }
}
