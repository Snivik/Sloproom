//
//  Catalog+LightroomImport.swift
//  sloproom
//
//  Writes a `LightroomImportPlan` into the Sloproom catalog. Idempotent:
//  - photos are upserted by path (existing rows keep their data; only `lr_image_id` is filled in
//    and LR's non-default pick/reject/rating are applied if those options are on),
//  - folders are matched on `folders.lr_collection_id` (existing ones are reused wherever the user
//    moved them; only missing ones are created), the container folder on `lightroomContainerID`,
//  - memberships use INSERT OR IGNORE.
//  Runs in chunked transactions (the DB lock is released between chunks so the UI stays
//  responsive) and posts change notifications once at the end. Call off the main thread; it
//  honours Task cancellation between chunks (already-written chunks stay; re-running completes).
//

import Foundation

nonisolated struct LightroomImportProgress: Sendable {
    /// 0...1
    var fraction: Double
    var message: String
}

nonisolated struct LightroomImportResult: Sendable {
    var photosAdded = 0
    /// Photos that were already in the catalog (matched by path).
    var photosExisting = 0
    var foldersCreated = 0
    var foldersReused = 0
    var membershipsAdded = 0
    var rootIDs: [Int64] = []
    var duration: TimeInterval = 0
}

nonisolated extension Catalog {
    /// `folders.lr_collection_id` of the "Lightroom" container folder (real LR ids are positive).
    static let lightroomContainerID: Int64 = 0

    @discardableResult
    func importLightroom(_ plan: LightroomImportPlan, importDate: Date = Date(),
                         progress: (LightroomImportProgress) -> Void = { _ in }) throws -> LightroomImportResult {
        let start = Date()
        var result = LightroomImportResult()
        var updatedIDs = Set<Int64>()
        defer {
            if result.photosAdded > 0 { postChange(.photosInsertedOrRemoved) }
            if !updatedIDs.isEmpty { postChange(.photosUpdated(updatedIDs)) }
            if result.foldersCreated > 0 { postChange(.folders) }
        }
        let options = plan.options

        // 1. Roots (no bookmark yet = access not granted; the user grants it per drive later).
        progress(.init(fraction: 0, message: "Adding root folders…"))
        for root in plan.snapshot.roots {
            let volume = RootAccess.volumeName(for: root.path)
            let name = volume.map { "\(root.name) (\($0))" } ?? root.name
            result.rootIDs.append(try upsertRoot(path: root.path, bookmark: nil, displayName: name))
        }
        let roots = try allRoots()

        // 2. Photos, in chunks.
        var photoIDs: [Int64: Int64] = [:]   // LR image id → Sloproom photo id
        photoIDs.reserveCapacity(plan.photos.count)
        let chunkSize = 2000
        for chunkStart in stride(from: 0, to: plan.photos.count, by: chunkSize) {
            try Task.checkCancellation()
            let chunk = plan.photos[chunkStart..<min(chunkStart + chunkSize, plan.photos.count)]
            try db.transaction {
                for image in chunk {
                    let flag = options.importFlags ? image.pick : 0
                    let rating = options.importRatings ? image.rating : 0
                    let rootID = Self.coveringRoot(for: image.path, in: roots)?.id
                    let inserted = try db.run("""
                        INSERT INTO photos(path, root_id, file_name, file_size, capture_date, import_date,
                            width, height, orientation, camera_model, lens, iso, shutter, aperture,
                            focal_length, flag, rating, sidecar_path, lr_image_id)
                        VALUES (?,?,?,0,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(path) DO NOTHING
                        """, [image.path, rootID, image.fileName, image.captureDate, importDate,
                              image.width, image.height, image.orientation, image.cameraModel, image.lens,
                              image.iso, image.shutter, image.aperture, image.focalLength, flag, rating,
                              image.sidecarPath, image.id])
                    if inserted > 0 {
                        photoIDs[image.id] = db.lastInsertRowID
                        result.photosAdded += 1
                    } else if let id = try db.scalarInt("SELECT id FROM photos WHERE path = ?", [image.path]) {
                        photoIDs[image.id] = id
                        result.photosExisting += 1
                        // Merge: keep Sloproom's data, only fill in what Lightroom knows and we don't.
                        let changed = try db.run("""
                            UPDATE photos SET lr_image_id = COALESCE(lr_image_id, ?),
                                flag = CASE WHEN ? != 0 THEN ? ELSE flag END,
                                rating = CASE WHEN ? > 0 THEN ? ELSE rating END,
                                sidecar_path = COALESCE(sidecar_path, ?)
                            WHERE id = ? AND (lr_image_id IS NULL OR (? != 0 AND flag != ?)
                                OR (? > 0 AND rating != ?) OR (sidecar_path IS NULL AND ? IS NOT NULL))
                            """, [image.id, flag, flag, rating, rating, image.sidecarPath, id,
                                  flag, flag, rating, rating, image.sidecarPath])
                        if changed > 0 { updatedIDs.insert(id) }
                    }
                }
            }
            let done = min(chunkStart + chunkSize, plan.photos.count)
            progress(.init(fraction: 0.9 * Double(done) / Double(max(plan.photos.count, 1)),
                           message: "Imported \(done.formatted()) of \(plan.photos.count.formatted()) photos…"))
        }

        // 3. Folders + memberships (one transaction; ~100 folders, ~15k memberships).
        try Task.checkCancellation()
        progress(.init(fraction: 0.9, message: "Creating folders…"))
        var touchedFolders = Set<Int64>()
        try db.transaction {
            var existing: [Int64: Int64] = [:]   // lr_collection_id → folder id
            for (lr, id) in try db.query("SELECT lr_collection_id, id FROM folders WHERE lr_collection_id IS NOT NULL ORDER BY id", [], { ($0.int(0), $0.int(1)) }) where existing[lr] == nil {
                existing[lr] = id
            }

            func folderID(lrID: Int64, name: String, parentID: Int64?) throws -> Int64 {
                if let id = existing[lrID] { result.foldersReused += 1; return id }
                let order = try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM folders WHERE parent_id IS ?", [parentID]) ?? 0
                try db.run("INSERT INTO folders(parent_id, name, sort_order, created_at, lr_collection_id) VALUES (?,?,?,?,?)",
                           [parentID, name, order, importDate, lrID])
                let id = db.lastInsertRowID
                existing[lrID] = id
                result.foldersCreated += 1
                return id
            }

            func create(_ node: LRFolderPlan, parentID: Int64?) throws {
                let id = try folderID(lrID: node.id, name: node.name, parentID: parentID)
                if !node.photoIDs.isEmpty {
                    var next = try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM folder_photos WHERE folder_id = ?", [id]) ?? 0
                    var added = 0
                    for lrImage in node.photoIDs {
                        guard let pid = photoIDs[lrImage] else { continue }
                        if try db.run("INSERT OR IGNORE INTO folder_photos(folder_id, photo_id, sort_order) VALUES (?,?,?)", [id, pid, next]) > 0 {
                            next += 1
                            added += 1
                        }
                    }
                    if added > 0 { touchedFolders.insert(id); result.membershipsAdded += added }
                }
                for child in node.children { try create(child, parentID: id) }
            }

            let top: Int64? = options.createContainerFolder && !plan.tree.isEmpty
                ? try folderID(lrID: Self.lightroomContainerID, name: options.containerName.trimmingCharacters(in: .whitespaces), parentID: nil)
                : nil
            for node in plan.tree { try create(node, parentID: top) }
        }
        if !touchedFolders.isEmpty { postChange(.folderMembership(touchedFolders)) }

        result.duration = Date().timeIntervalSince(start)
        progress(.init(fraction: 1, message: "Done"))
        return result
    }
}
