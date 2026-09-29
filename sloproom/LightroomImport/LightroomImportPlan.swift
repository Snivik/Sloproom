//
//  LightroomImportPlan.swift
//  sloproom
//
//  What an import WOULD do for a snapshot + options: the photos to insert and the folder tree
//  (collection sets and collections both become Sloproom folders). Pure and cheap (a few ms for
//  20k images), so the sheet recomputes it whenever an option changes. Engine code.
//
//  Virtual copies are mapped to their master: the master photo is imported once and joins every
//  collection any of its virtual copies was in (Sloproom has no virtual copies; edits aren't imported).
//

import Foundation

nonisolated struct LightroomImportOptions: Hashable, Sendable {
    enum PhotoScope: String, Hashable, Sendable, CaseIterable {
        /// Every photo in the catalog.
        case all
        /// Only photos that are members of an imported collection.
        case inCollections
    }

    var scope: PhotoScope = .all
    var importFlags = true
    var importRatings = true
    var includeVideos = false
    var includeQuickCollection = false
    /// Put everything under one new top-level folder (`containerName`) instead of at top level.
    var createContainerFolder = true
    var containerName = "Lightroom"
}

/// One folder to create (from a collection set or a collection).
nonisolated struct LRFolderPlan: Identifiable, Hashable, Sendable {
    /// Lightroom collection id (stored as `folders.lr_collection_id`).
    var id: Int64
    var name: String
    var isSet: Bool
    /// Lightroom image ids of the member photos (masters), in Lightroom order, no duplicates.
    var photoIDs: [Int64]
    var children: [LRFolderPlan]
    /// Distinct photos in this folder and all subfolders.
    var subtreePhotoCount: Int

    var childrenOrNil: [LRFolderPlan]? { children.isEmpty ? nil : children }
    var folderCount: Int { 1 + children.reduce(0) { $0 + $1.folderCount } }
}

nonisolated struct LightroomImportPlan: Sendable {
    let snapshot: LightroomCatalogSnapshot
    let options: LightroomImportOptions
    /// Photos to insert (masters only), sorted by path.
    let photos: [LRImage]
    /// Top-level folders in Lightroom's panel order (sets first, then collections, by name).
    let tree: [LRFolderPlan]
    let skippedSmartCollections: [String]
    /// Collection sets not created because they contain no regular collection (e.g. LR's
    /// default "Smart Collections" set).
    let skippedEmptySets: [String]
    let skippedVideoCount: Int
    /// Virtual copies in the catalog (mapped to their masters).
    let virtualCopyCount: Int

    /// Distinct photos that end up in at least one folder.
    let photosInFoldersCount: Int

    var folderCount: Int { tree.reduce(0) { $0 + $1.folderCount } }
    var membershipCount: Int {
        func count(_ n: LRFolderPlan) -> Int { n.photoIDs.count + n.children.reduce(0) { $0 + count($1) } }
        return tree.reduce(0) { $0 + count($1) }
    }

    init(snapshot: LightroomCatalogSnapshot, options: LightroomImportOptions) {
        self.snapshot = snapshot
        self.options = options

        func importable(_ image: LRImage) -> Bool { options.includeVideos || !image.isVideo }

        // Collections → folder plans (bottom-up so sets know whether they contain anything).
        let byParent = Dictionary(grouping: snapshot.collections) { $0.parentID ?? 0 }
        var skippedSets: [String] = []
        func build(_ c: LRCollection) -> LRFolderPlan? {
            switch c.kind {
            case .smart: return nil
            case .quick: guard options.includeQuickCollection else { return nil }
            case .set, .collection: break
            }
            if c.kind == .set {
                let children = Self.ordered(byParent[c.id] ?? []).compactMap(build)
                guard !children.isEmpty else { skippedSets.append(c.name); return nil }
                let distinct = children.reduce(into: Set<Int64>()) { $0.formUnion(Self.subtreeIDs($1)) }
                return LRFolderPlan(id: c.id, name: c.name, isSet: true, photoIDs: [], children: children,
                                    subtreePhotoCount: distinct.count)
            }
            var seen = Set<Int64>()
            var ids: [Int64] = []
            for member in c.imageIDs {
                guard let m = snapshot.masterImage(of: member), importable(m), seen.insert(m.id).inserted else { continue }
                ids.append(m.id)
            }
            let name = c.kind == .quick ? "Quick Collection" : c.name
            return LRFolderPlan(id: c.id, name: name, isSet: false, photoIDs: ids, children: [], subtreePhotoCount: ids.count)
        }
        let known = Set(snapshot.collections.map(\.id))
        let topLevel = snapshot.collections.filter { $0.parentID == nil || !known.contains($0.parentID!) }
        tree = Self.ordered(topLevel).compactMap(build)
        skippedEmptySets = skippedSets

        let inFolders = tree.reduce(into: Set<Int64>()) { $0.formUnion(Self.subtreeIDs($1)) }
        photosInFoldersCount = inFolders.count
        switch options.scope {
        case .all:
            photos = snapshot.images.filter { !$0.isVirtualCopy && importable($0) }.sorted { $0.path < $1.path }
        case .inCollections:
            photos = inFolders.compactMap(snapshot.image(id:)).sorted { $0.path < $1.path }
        }
        skippedSmartCollections = snapshot.collections(of: .smart).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        skippedVideoCount = options.includeVideos ? 0 : snapshot.videoCount
        virtualCopyCount = snapshot.virtualCopyCount
    }

    /// Lightroom's "Sort by Name" panel order: collection sets first, then collections, by name.
    private static func ordered(_ collections: [LRCollection]) -> [LRCollection] {
        collections.sorted { a, b in
            let (sa, sb) = (a.kind == .set, b.kind == .set)
            if sa != sb { return sa }
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? a.id < b.id : r == .orderedAscending
        }
    }

    private static func subtreeIDs(_ node: LRFolderPlan) -> Set<Int64> {
        node.children.reduce(into: Set(node.photoIDs)) { $0.formUnion(subtreeIDs($1)) }
    }
}
