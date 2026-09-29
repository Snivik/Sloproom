//
//  folders_check.swift
//  Headless test of folder management + flag counts (catalog side, drag payloads, drop planning).
//
//    Tools/harness.sh /private/tmp/claude-501/out-folders/folders_check Tools/folders_check.swift \
//        sloproom/App/FolderTree.swift sloproom/Library/Sidebar/Catalog+FolderManagement.swift \
//        sloproom/Library/Sidebar/FolderDragPayload.swift
//    /private/tmp/claude-501/out-folders/folders_check [out-dir]
//
//  Uses synthetic photo rows (no image files needed); writes only a temp catalog into out-dir.
//

import Foundation

@main
struct FoldersCheck {
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
        let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/private/tmp/claude-501/out-folders")
        let dir = outDir.appendingPathComponent("folders-catalog-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog.open(at: dir)

        let photos = (0..<20).map { i -> Photo in
            var p = Photo(path: "/test/IMG_\(String(format: "%04d", i)).DNG")
            p.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            return p
        }
        let ids = try catalog.insertPhotos(photos)

        // MARK: Tree + sort orders
        print("Folders")
        let trips = try catalog.createFolder(name: "Trips")
        let italy = try catalog.createFolder(name: "Italy", parentID: trips)
        let rome = try catalog.createFolder(name: "Rome", parentID: italy)
        let japan = try catalog.createFolder(name: "Japan", parentID: trips)
        let portfolio = try catalog.createFolder(name: "Portfolio")
        let misc = try catalog.createFolder(name: "Misc")
        func children(_ parent: Int64?) throws -> [Int64] {
            FolderDropPlanner.sortedChildren(of: parent, in: try catalog.allFolders()).map(\.id)
        }
        check(try children(nil) == [trips, portfolio, misc], "top level in creation order")
        check(try children(trips) == [italy, japan], "children in creation order")
        check(FolderTree.build(try catalog.allFolders()).map(\.id) == [trips, portfolio, misc], "FolderTree order matches planner order")

        // MARK: Cycle prevention
        var threw = false
        do { try catalog.moveFolder(id: trips, toParent: rome) } catch CatalogError.folderCycle { threw = true }
        check(threw, "moving into a descendant throws folderCycle")
        threw = false
        do { try catalog.moveFolder(id: italy, toParent: italy) } catch CatalogError.folderCycle { threw = true }
        check(threw, "moving into itself throws folderCycle")
        check(try catalog.folder(id: trips)?.parentID == nil, "failed move leaves tree unchanged")

        // MARK: Drop planner
        var folders = try catalog.allFolders()
        check(FolderDropPlanner.destination(moving: trips, onto: rome, zone: .into, folders: folders) == nil, "planner: into descendant rejected")
        check(FolderDropPlanner.destination(moving: trips, onto: rome, zone: .before, folders: folders) == nil, "planner: beside descendant rejected")
        check(FolderDropPlanner.destination(moving: trips, onto: trips, zone: .into, folders: folders) == nil, "planner: onto itself rejected")
        check(FolderDropPlanner.destination(moving: italy, onto: trips, zone: .into, folders: folders) == nil, "planner: into current parent is a no-op")
        check(FolderDropPlanner.destination(moving: portfolio, onto: trips, zone: .after, folders: folders) == nil, "planner: after previous sibling is a no-op")
        check(FolderDropPlanner.destination(moving: portfolio, onto: misc, zone: .before, folders: folders) == nil, "planner: before next sibling is a no-op")
        check(FolderDropPlanner.destination(moving: misc, onto: trips, zone: .before, folders: folders) == .init(parentID: nil, index: 0), "planner: before first")
        check(FolderDropPlanner.destination(moving: trips, onto: misc, zone: .after, folders: folders) == .init(parentID: nil, index: 2), "planner: after last")
        check(FolderDropPlanner.destination(moving: misc, onto: italy, zone: .after, folders: folders) == .init(parentID: trips, index: 1), "planner: between nested siblings")
        check(FolderDropPlanner.destination(moving: rome, onto: portfolio, zone: .into, folders: folders) == .init(parentID: portfolio, index: nil), "planner: nest into other folder")
        check(FolderDropPlanner.topLevelDestination(moving: rome, folders: folders) == .init(parentID: nil, index: nil), "planner: un-nest to top level")
        check(FolderDropPlanner.topLevelDestination(moving: misc, folders: folders) == nil, "planner: last top-level folder to top level is a no-op")
        check(FolderDropZone(y: 2, height: 24) == .before && FolderDropZone(y: 12, height: 24) == .into && FolderDropZone(y: 22, height: 24) == .after, "drop zones by y")

        // Apply planner results through the catalog.
        func apply(_ id: Int64, _ d: FolderDropPlanner.Destination?) throws {
            guard let d else { failures += 1; print("  FAIL no destination"); return }
            try catalog.moveFolder(id: id, toParent: d.parentID, index: d.index)
        }
        try apply(misc, FolderDropPlanner.destination(moving: misc, onto: trips, zone: .before, folders: folders))
        check(try children(nil) == [misc, trips, portfolio], "reorder: Misc moved before Trips")
        folders = try catalog.allFolders()
        try apply(misc, FolderDropPlanner.destination(moving: misc, onto: italy, zone: .after, folders: folders))
        check(try children(trips) == [italy, misc, japan] && children(nil) == [trips, portfolio], "nest between siblings: Trips > Italy, Misc, Japan")
        folders = try catalog.allFolders()
        try apply(misc, FolderDropPlanner.destination(moving: misc, onto: italy, zone: .before, folders: folders))
        check(try children(trips) == [misc, italy, japan], "reorder within parent (move up)")
        folders = try catalog.allFolders()
        try apply(misc, FolderDropPlanner.destination(moving: misc, onto: japan, zone: .after, folders: folders))
        check(try children(trips) == [italy, japan, misc], "reorder within parent (move down)")
        folders = try catalog.allFolders()
        try apply(misc, FolderDropPlanner.topLevelDestination(moving: misc, folders: folders))
        check(try children(nil) == [trips, portfolio, misc] && children(trips) == [italy, japan], "un-nest appends at top level")
        check(FolderTree.build(try catalog.allFolders()).map(\.id) == [trips, portfolio, misc], "FolderTree agrees after moves")

        // MARK: Membership: add / move / remove
        print("Membership")
        try catalog.addPhotos(ids[0..<10], toFolder: italy)
        try catalog.addPhotos(ids[5..<12], toFolder: rome)
        try catalog.addPhotos(ids[0..<3], toFolder: japan)
        try catalog.addPhotos(ids[0..<3], toFolder: japan) // duplicates ignored
        let direct = try catalog.folderPhotoCounts()
        check(direct[italy] == 10 && direct[rome] == 7 && direct[japan] == 3 && direct[trips] == nil, "direct counts")
        let totals = try catalog.folderTotalPhotoCounts()
        check(totals[italy] == 12, "total incl. subfolders is distinct (Italy 10 + Rome 7 overlapping 5 = 12), got \(totals[italy] ?? -1)")
        check(totals[trips] == 12 && totals[rome] == 7 && totals[japan] == 3 && totals[portfolio] == nil, "totals roll up to ancestors")
        for f in try catalog.allFolders() {
            check(try catalog.photoCount(folderID: f.id, includeSubfolders: true) == (totals[f.id] ?? 0), "total matches photoCount(includeSubfolders:) for \(f.name)")
        }

        try catalog.movePhotos(ids[0..<2], fromFolders: [italy], to: portfolio)
        check(try catalog.photoCount(folderID: italy) == 8 && catalog.photoCount(folderID: portfolio) == 2, "move: removed from source, added to destination")
        check(try Set(catalog.folderIDs(containing: ids[0])) == [japan, portfolio], "move keeps other memberships")
        // ⌥-drop while viewing Trips with subfolders shown: remove from the whole subtree except the destination.
        let tripsSubtree = try catalog.folderSubtreeIDs(trips)
        try catalog.movePhotos([ids[6]], fromFolders: tripsSubtree, to: rome)
        check(try Set(catalog.folderIDs(containing: ids[6])) == [rome], "move from subtree keeps destination inside it")
        try catalog.removePhotos([ids[2], ids[7]], fromFolders: tripsSubtree)
        check(try catalog.folderIDs(containing: ids[2]).isEmpty && catalog.folderIDs(containing: ids[7]).isEmpty, "remove from folder subtree")
        check(try catalog.totalPhotoCount() == 20, "removing from folders keeps photos in catalog")
        let orders = try catalog.db.query("SELECT sort_order FROM folder_photos WHERE folder_id = ? ORDER BY sort_order", [portfolio]) { Int($0.int(0)) }
        check(orders == [0, 1], "moved photos get sequential sort orders in destination")

        // MARK: Unique names
        check(try catalog.uniqueFolderName("Untitled Folder", parentID: nil) == "Untitled Folder", "unique name: free")
        _ = try catalog.createFolder(name: "Untitled Folder")
        _ = try catalog.createFolder(name: "untitled folder 2")
        check(try catalog.uniqueFolderName("Untitled Folder", parentID: nil) == "Untitled Folder 3", "unique name: case-insensitive suffix")
        check(try catalog.uniqueFolderName("Untitled Folder", parentID: trips) == "Untitled Folder", "unique name: per parent")

        // MARK: Flags
        print("Flags")
        try catalog.setFlag(.pick, for: ids[0..<4])
        try catalog.setFlag(.reject, for: ids[4..<7])
        let fc = try catalog.flagCounts()
        check(fc.picked == 4 && fc.rejected == 3 && fc.unflagged == 13 && fc.total == 20, "flag counts")
        check(try catalog.photos(in: .all, filter: PhotoFilter(flag: .notRejected)).count == 17, "not-rejected filter")

        // MARK: Delete cascade
        print("Delete")
        try catalog.deleteFolder(id: trips)
        let left = try catalog.allFolders().map(\.id)
        check(!left.contains(trips) && !left.contains(italy) && !left.contains(rome) && !left.contains(japan), "delete cascades to subfolders")
        check(try catalog.folderPhotoCounts()[italy] == nil && catalog.folderIDs(containing: ids[5]).isEmpty, "delete cascades memberships")
        check(try catalog.totalPhotoCount() == 20 && catalog.photoCount(folderID: portfolio) == 2, "delete keeps photos and other folders")

        // MARK: Drag payloads
        print("Drag payloads")
        check(SloproomDragPayload(string: SloproomDragPayload.photos([3, 1, 2]).string) == .photos([3, 1, 2]), "photos payload round trip keeps order")
        check(SloproomDragPayload(string: SloproomDragPayload.folder(42).string) == .folder(42), "folder payload round trip")
        check(SloproomDragPayload(string: "hello") == nil && SloproomDragPayload(string: "sloproom-drag:photos:") == nil
              && SloproomDragPayload(string: "sloproom-drag:folder:x") == nil, "foreign / malformed text rejected")

        // MARK: Scale: 100 folders x 22k photos
        print("Scale (22k photos, 100 folders)")
        let big = try Catalog.open(at: dir.appendingPathComponent("big"))
        let many = (0..<22_000).map { Photo(path: "/big/P\($0).DNG") }
        let bigIDs = try time("insert 22k photos") { try big.insertPhotos(many) }
        var folderIDs: [Int64] = []
        for i in 0..<100 {
            // 10 top-level folders, each with 3 levels of nesting below.
            let parent: Int64? = i % 10 == 0 ? nil : folderIDs[i - 1]
            folderIDs.append(try big.createFolder(name: "F\(i)", parentID: parent))
        }
        try big.db.transaction {
            for (i, fid) in folderIDs.enumerated() {
                let start = (i * 220) % 22_000
                try big.addPhotos(bigIDs[start..<min(start + 2_000, 22_000)], toFolder: fid)
            }
        }
        _ = try time("allFolders + direct counts") { (try big.allFolders(), try big.folderPhotoCounts()) }
        let bigTotals = try time("folderTotalPhotoCounts (grouped)") { try big.folderTotalPhotoCounts() }
        check(bigTotals[folderIDs[0]] == (try big.photoCount(folderID: folderIDs[0], includeSubfolders: true)), "grouped total matches per-folder query at scale")
        _ = try time("flagCounts") { try big.flagCounts() }
        _ = try time("FolderTree.build") { FolderTree.build(try big.allFolders()) }
        try time("move 5000 photos between folders") { try big.movePhotos(bigIDs[0..<5000], fromFolders: [folderIDs[0]], to: folderIDs[50]) }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        if failures > 0 { exit(1) }
    }
}
