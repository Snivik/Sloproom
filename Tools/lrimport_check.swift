//
//  lrimport_check.swift
//  Headless check of the Lightroom Classic catalog importer (engine only, no UI).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/out-lrimport/lrimport_check Tools/lrimport_check.swift \
//      sloproom/LightroomImport/LightroomCatalogReader.swift sloproom/LightroomImport/LightroomImportPlan.swift \
//      sloproom/LightroomImport/Catalog+LightroomImport.swift sloproom/LightroomImport/RootAccess.swift sloproom/App/FolderTree.swift
//    /private/tmp/claude-501/out-lrimport/lrimport_check <catalog.lrcat> [out-dir]
//
//  Copies the .lrcat into out-dir (never opens the original), imports it into a fresh temp
//  Sloproom catalog, prints counts / the folder tree / timings, then imports AGAIN and checks
//  that nothing was duplicated.
//

import Foundation

@main
struct LightroomImportCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func ms(_ t: TimeInterval) -> String { String(format: "%.0f ms", t * 1000) }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count > 1 else { print("usage: lrimport_check <catalog.lrcat> [out-dir]"); exit(2) }
        let lrcat = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-lrimport")
        let catalogDir = outDir.appendingPathComponent("check-catalog-\(Int(Date().timeIntervalSince1970))")

        // MARK: Decoding helpers
        print("Field decoding")
        let local = LightroomCatalogReader.parseCaptureTime("2021-07-30T23:54:00.250")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let expected = cal.date(from: DateComponents(year: 2021, month: 7, day: 30, hour: 23, minute: 54))!.addingTimeInterval(0.25)
        check(local.map { abs($0.timeIntervalSince(expected)) < 0.001 } ?? false, "captureTime local wall clock + fraction")
        check(LightroomCatalogReader.parseCaptureTime("2021-07-30T23:54:00Z") == Date(timeIntervalSince1970: 1627689240), "captureTime Z")
        check(LightroomCatalogReader.parseCaptureTime("2021-07-31T01:54:00+02:00") == Date(timeIntervalSince1970: 1627689240), "captureTime offset")
        check(LightroomCatalogReader.orientation(fromLightroom: "DA") == 8 && LightroomCatalogReader.orientation(fromLightroom: "BC") == 6
              && LightroomCatalogReader.orientation(fromLightroom: nil) == 1, "orientation codes")
        check(LightroomCatalogReader.joinPath("/Volumes/T9/Lightroom/", "2026/2026-08-01/") == "/Volumes/T9/Lightroom/2026/2026-08-01", "joinPath")
        check(RootAccess.volumeName(for: "/Volumes/Samsung T7/Lightroom") == "Samsung T7" && RootAccess.volumeName(for: "/Users/x") == nil, "volumeName")

        // MARK: Read
        print("\nReading \(lrcat.path) (via a temp copy)")
        let snapshot = try LightroomCatalogReader.load(copying: lrcat, tempDirectory: outDir.appendingPathComponent("tmp"))
        print("  loaded in \(ms(snapshot.loadDuration)): \(snapshot.images.count) images, \(snapshot.photoCount) photos, "
              + "\(snapshot.videoCount) videos, \(snapshot.virtualCopyCount) virtual copies")
        print("  sets \(snapshot.collections(of: .set).count), collections \(snapshot.collections(of: .collection).count), "
              + "smart \(snapshot.collections(of: .smart).count), quick \(snapshot.collections(of: .quick).map { $0.imageIDs.count })")
        let mounted = RootAccess.mountedVolumePaths()
        for root in snapshot.roots {
            print("  root \(root.path) [\(root.name)] \(RootAccess.isOnline(root.path, mounted: mounted) ? "online" : "offline")")
        }
        check(try FileManager.default.contentsOfDirectory(atPath: outDir.appendingPathComponent("tmp").path).isEmpty, "temp copy deleted after reading")
        if let sample = snapshot.images.first(where: { $0.fileName == "L1090229.DNG" }) {
            print("  sample: \(sample.path) orient \(sample.orientation) \(sample.width)x\(sample.height) captured \(sample.captureDate.map { "\($0)" } ?? "nil") "
                  + "sidecar \(sample.sidecarPath ?? "-") \(sample.cameraModel ?? "-") / \(sample.lens ?? "-") ISO \(sample.iso ?? 0) "
                  + "1/\(Int((1 / (sample.shutter ?? 1)).rounded()))s f/\(sample.aperture ?? 0) \(sample.focalLength ?? 0)mm")
            check(sample.orientation == 8 && sample.sidecarPath?.hasSuffix("L1090229.JPG") == true, "sample orientation + sidecar match the file on disk")
        }

        // MARK: Plan
        let options = LightroomImportOptions()
        let t0 = Date()
        let plan = LightroomImportPlan(snapshot: snapshot, options: options)
        print("\nPlan (\(ms(Date().timeIntervalSince(t0)))): \(plan.photos.count) photos, \(plan.folderCount) folders (+ container), "
              + "\(plan.membershipCount) memberships")
        print("  skipped smart: \(plan.skippedSmartCollections.joined(separator: ", "))")
        print("  skipped empty sets: \(plan.skippedEmptySets.joined(separator: ", "))")
        print("  skipped videos: \(plan.skippedVideoCount), virtual copies mapped to masters: \(plan.virtualCopyCount)")
        let onlyInCollections = LightroomImportPlan(snapshot: snapshot, options: .init(scope: .inCollections))
        print("  'only photos in collections' would import \(onlyInCollections.photos.count) photos")

        // MARK: Import #1
        print("\nImport #1 into \(catalogDir.path)")
        let catalog = try Catalog.open(at: catalogDir)
        var lastProgress = -1.0
        let r1 = try catalog.importLightroom(plan) { p in
            if p.fraction - lastProgress >= 0.25 || p.fraction == 1 { print(String(format: "  %3.0f%% %@", p.fraction * 100, p.message)); lastProgress = p.fraction }
        }
        print("  \(ms(r1.duration)): photos added \(r1.photosAdded), existing \(r1.photosExisting), folders created \(r1.foldersCreated), "
              + "reused \(r1.foldersReused), memberships \(r1.membershipsAdded)")
        let photoCount1 = try catalog.totalPhotoCount()
        let folderCount1 = try catalog.allFolders().count
        let memberships1 = try catalog.db.scalarInt("SELECT COUNT(*) FROM folder_photos") ?? 0
        check(photoCount1 == plan.photos.count, "all planned photos inserted (\(photoCount1))")
        check(folderCount1 == plan.folderCount + 1, "all planned folders + container created (\(folderCount1))")
        check(Int(memberships1) == plan.membershipCount, "all memberships added (\(memberships1))")
        check(try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE lr_image_id IS NULL") == 0, "every photo has lr_image_id")
        check(try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE root_id IS NULL") == 0, "every photo attached to a root")
        let picks = try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE flag = 1") ?? 0
        let rated = try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE rating > 0") ?? 0
        let lrPicks = plan.photos.filter { $0.pick == 1 }.count, lrRated = plan.photos.filter { $0.rating > 0 }.count
        check(picks == lrPicks && rated == lrRated, "flags (\(picks)) and ratings (\(rated)) imported")
        print("  roots:")
        for root in try catalog.allRoots() {
            let n = try catalog.db.scalarInt("SELECT COUNT(*) FROM photos WHERE root_id = ?", [root.id]) ?? 0
            print("    \(root.path) “\(root.displayName ?? "")” bookmark \(root.bookmark == nil ? "none" : "yes") — \(n) photos — \(RootAccess.status(of: root, mounted: mounted).title)")
        }

        // MARK: Tree
        print("\nFolder tree (direct / incl. subfolders):")
        let folders = try catalog.allFolders()
        let counts = try catalog.folderPhotoCounts()
        func printTree(_ nodes: [FolderNode], _ depth: Int) throws {
            for n in nodes {
                let sub = try catalog.photoCount(folderID: n.id, includeSubfolders: true)
                print(String(repeating: "  ", count: depth + 1) + "\(n.folder.name)  [\(counts[n.id] ?? 0) / \(sub)]")
                try printTree(n.children, depth + 1)
            }
        }
        let tree = FolderTree.build(folders)
        try printTree(tree, 0)
        print("\nPhotos per top-level folder:")
        for n in tree.flatMap({ $0.folder.lrCollectionID == Catalog.lightroomContainerID ? $0.children : [$0] }) {
            print("  \(try catalog.photoCount(folderID: n.id, includeSubfolders: true))\t\(n.folder.name)")
        }

        // Folder order within a collection keeps Lightroom's order.
        if let first = plan.tree.first(where: { !$0.isSet && $0.photoIDs.count > 2 }),
           let fid = try catalog.db.scalarInt("SELECT id FROM folders WHERE lr_collection_id = ?", [first.id]) {
            let order = try catalog.photos(in: .folder(id: fid, includeSubfolders: false), sort: .init(key: .folderOrder)).compactMap(\.lrImageID)
            check(order == first.photoIDs, "folder order matches Lightroom order (\(first.name))")
        }

        // MARK: Import #2 (idempotency) — also flip a Sloproom-side flag to prove it survives.
        print("\nImport #2 (same catalog, same options)")
        let someID = try catalog.db.scalarInt("SELECT id FROM photos WHERE flag = 0 LIMIT 1") ?? 0
        try catalog.setFlag(.reject, for: [someID])
        let r2 = try catalog.importLightroom(plan)
        print("  \(ms(r2.duration)): photos added \(r2.photosAdded), existing \(r2.photosExisting), folders created \(r2.foldersCreated), "
              + "reused \(r2.foldersReused), memberships \(r2.membershipsAdded)")
        check(r2.photosAdded == 0 && r2.foldersCreated == 0 && r2.membershipsAdded == 0, "second import adds nothing")
        check(try catalog.totalPhotoCount() == photoCount1, "photo count unchanged")
        check(try catalog.allFolders().count == folderCount1, "folder count unchanged")
        check(try catalog.db.scalarInt("SELECT COUNT(*) FROM folder_photos") == memberships1, "membership count unchanged")
        check(try catalog.db.scalarInt("SELECT COUNT(*) FROM (SELECT lr_collection_id FROM folders GROUP BY 1 HAVING COUNT(*) > 1)") == 0, "no duplicate lr_collection_id")
        check(try catalog.photo(id: someID)?.flag == .reject, "Sloproom-side flag kept on re-import")
        check(try catalog.allRoots().count == snapshot.roots.count, "roots not duplicated")

        // Re-import at top level after the user moved a folder: still no duplicates.
        let moved = try catalog.allFolders().first { $0.lrCollectionID != nil && $0.lrCollectionID != 0 && $0.parentID != nil }!
        try catalog.moveFolder(id: moved.id, toParent: nil)
        let r3 = try catalog.importLightroom(LightroomImportPlan(snapshot: snapshot, options: .init(createContainerFolder: false)))
        check(try r3.foldersCreated == 0 && (catalog.folder(id: moved.id)?.parentID) == nil, "re-import (top level) reuses moved folders")

        // "Only photos in collections" into a fresh catalog.
        let catalog2 = try Catalog.open(at: catalogDir.appendingPathComponent("only-collections"))
        let r4 = try catalog2.importLightroom(onlyInCollections)
        check(try r4.photosAdded == onlyInCollections.photos.count && (catalog2.db.scalarInt("SELECT COUNT(*) FROM photos p WHERE NOT EXISTS (SELECT 1 FROM folder_photos fp WHERE fp.photo_id = p.id)")) == 0,
              "'only in collections': \(r4.photosAdded) photos, all in a folder (\(ms(r4.duration)))")

        // Cancellation between chunks.
        let catalog3 = try Catalog.open(at: catalogDir.appendingPathComponent("cancel"))
        let task = Task.detached { () -> Bool in
            do {
                try catalog3.importLightroom(plan) { p in if p.fraction > 0.2 { withUnsafeCurrentTask { $0?.cancel() } } }
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        let cancelled = await task.value
        let partial = try catalog3.totalPhotoCount()
        check(try cancelled && partial > 0 && partial < plan.photos.count && (catalog3.allFolders().isEmpty), "cancel stops between chunks (\(partial) photos kept)")
        _ = try catalog3.importLightroom(plan)
        check(try catalog3.totalPhotoCount() == plan.photos.count, "re-run after cancel completes")

        // MARK: Grant access (RootsAccessView's engine) on local folders.
        print("\nGrant access")
        let drive = catalogDir.appendingPathComponent("FakeDrive", isDirectory: true)
        let lrRoot = drive.appendingPathComponent("Lightroom", isDirectory: true)
        try FileManager.default.createDirectory(at: lrRoot.appendingPathComponent("2026"), withIntermediateDirectories: true)
        let catalog4 = try Catalog.open(at: catalogDir.appendingPathComponent("grant"))
        let rootID = try catalog4.upsertRoot(path: lrRoot.path, bookmark: nil, displayName: "Lightroom")
        // Standardized ("/tmp/…" not "/private/tmp/…"), as upsertRoot matches stored paths by prefix.
        let pid = try catalog4.insertPhoto(Photo(path: Catalog.normalizedRootPath(lrRoot.path) + "/2026/a.DNG"))
        let root = try catalog4.root(id: rootID)!
        check(RootAccess.status(of: root) == .needsAccess, "local root without bookmark needs access")
        do { try RootAccess.grant(root, pickedURL: catalogDir.appendingPathComponent("elsewhere"), catalog: catalog4); check(false, "wrong folder rejected") }
        catch { check(error is RootAccess.GrantError, "wrong folder rejected") }
        let same = try RootAccess.grant(root, pickedURL: lrRoot, catalog: catalog4)
        check(same.id == rootID && same.bookmark != nil && RootAccess.status(of: same) == .granted, "granting the root itself stores a bookmark")
        try catalog4.db.run("UPDATE roots SET bookmark = NULL")
        let parent = try RootAccess.grant(try catalog4.root(id: rootID)!, pickedURL: drive, catalog: catalog4)
        check(try parent.path == Catalog.normalizedRootPath(drive.path) && catalog4.allRoots().count == 1
              && catalog4.photo(id: pid)?.rootID == parent.id, "granting the drive replaces the inner root and re-attaches its photos")
        check(try RootAccess.roots(covering: [lrRoot.path], in: catalog4).map(\.id) == [parent.id], "roots(covering:) finds the parent root")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
