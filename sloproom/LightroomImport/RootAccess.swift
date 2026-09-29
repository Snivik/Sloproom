//
//  RootAccess.swift
//  sloproom
//
//  Online / offline / access-granted status of roots, granting access to a root by picking
//  it (or one of its parent folders, e.g. the whole drive) in an open panel, and relinking a root
//  to a different path (`RootAccess.relink`, `Catalog.relinkCheck` / `relinkRoot`). Engine part of
//  `RootsAccessView`; no SwiftUI/AppKit.
//

import Foundation

nonisolated enum RootAccessStatus: Hashable, Sendable {
    /// The drive is not connected.
    case offline(hasBookmark: Bool)
    /// Drive connected, but the sandboxed app has no grant for it yet.
    case needsAccess
    /// A stored security-scoped bookmark resolves.
    case granted

    var title: String {
        switch self {
        case .offline(let hasBookmark): hasBookmark ? "Offline · access saved" : "Offline"
        case .needsAccess: "Online · needs access"
        case .granted: "Access granted"
        }
    }
}

nonisolated enum RootAccess {
    /// "/Volumes/T9/Lightroom" → "T9"; nil for paths on the startup disk.
    static func volumeName(for path: String) -> String? {
        let parts = (path as NSString).pathComponents   // ["/", "Volumes", "T9", …]
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return parts[2]
    }

    /// Mount point of the volume holding `path` ("/Volumes/T9", or "/" for the startup disk).
    static func volumePath(for path: String) -> String {
        volumeName(for: path).map { "/Volumes/\($0)" } ?? "/"
    }

    /// Mount points of the currently mounted volumes (works in the sandbox, unlike stat-ing paths).
    static func mountedVolumePaths() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(urls.map { Catalog.normalizedRootPath($0.path) })
    }

    static func isOnline(_ path: String, mounted: Set<String>? = nil) -> Bool {
        let volume = volumePath(for: path)
        if volume == "/" { return true }
        return (mounted ?? mountedVolumePaths()).contains(volume) || FileManager.default.fileExists(atPath: path)
    }

    static func status(of root: Root, mounted: Set<String>? = nil) -> RootAccessStatus {
        guard isOnline(root.path, mounted: mounted) else { return .offline(hasBookmark: root.bookmark != nil) }
        guard let bookmark = root.bookmark, (try? SecurityScope.resolveBookmark(bookmark)) != nil else { return .needsAccess }
        return .granted
    }

    /// Roots equal to or containing any of `paths` (nil = all roots), sorted by path.
    static func roots(covering paths: [String]?, in catalog: Catalog) throws -> [Root] {
        let all = try catalog.allRoots()
        guard let paths else { return all }
        let normalized = paths.map(Catalog.normalizedRootPath)
        return all.filter { root in
            normalized.contains { $0 == root.path || $0.hasPrefix(root.path == "/" ? "/" : root.path + "/") }
        }
    }

    nonisolated enum GrantError: Error, CustomStringConvertible {
        case wrongFolder(chosen: String, expected: String)
        var description: String {
            switch self {
            case .wrongFolder(let chosen, let expected):
                "“\(chosen)” does not contain “\(expected)”. Choose that folder, or the drive it is on."
            }
        }
    }

    /// Stores a grant for `root` after the user picked `url` in an open panel (call right after the
    /// panel returns). `url` must be the root itself or one of its parents (e.g. the drive). When it
    /// is a parent, the picked folder becomes the root and bookmark-less roots inside it are
    /// replaced by it (their photos are re-attached), so every photo resolves to a granted root.
    @discardableResult
    static func grant(_ root: Root, pickedURL url: URL, catalog: Catalog) throws -> Root {
        let chosen = Catalog.normalizedRootPath(url.path)
        let isSame = chosen == root.path
        let isParent = root.path.hasPrefix(chosen == "/" ? "/" : chosen + "/")
        guard isSame || isParent else { throw GrantError.wrongFolder(chosen: chosen, expected: root.path) }
        // Forget cached scope failures (the root may have been tried while offline).
        SecurityScopeManager.shared.reset()
        if isParent {
            let prefix = chosen == "/" ? "/" : chosen + "/"
            for inner in try catalog.allRoots() where inner.bookmark == nil && inner.path.hasPrefix(prefix) {
                try catalog.removeRoot(id: inner.id)
            }
            return try SecurityScopeManager.shared.registerRoot(url: url, in: catalog)
        }
        return try SecurityScopeManager.shared.registerRoot(url: url, in: catalog, displayName: root.displayName)
    }

    /// Relinks `root` to a folder at a DIFFERENT path (renamed drive, other Mac): rewrites the root
    /// and all its photo paths (`Catalog.relinkRoot`) and stores `bookmark` (create it right after
    /// the open panel returned `url`). Picking the root's own path is a plain grant.
    @discardableResult
    static func relink(_ root: Root, to url: URL, bookmark: Data?, catalog: Catalog) throws -> RelinkResult {
        let newPath = Catalog.normalizedRootPath(url.path)
        if newPath == root.path {
            try grant(root, pickedURL: url, catalog: catalog)
            return RelinkResult(rootID: root.id, oldPath: root.path, newPath: newPath, photoIDs: [], sidecarsRewritten: 0)
        }
        let name = url.lastPathComponent + (volumeName(for: newPath).map { " (\($0))" } ?? "")
        let result = try catalog.relinkRoot(id: root.id, to: newPath, bookmark: bookmark, displayName: name)
        // Scopes are cached per root id; the old URL must not be reused.
        SecurityScopeManager.shared.reset()
        if bookmark != nil { SecurityScopeManager.shared.ensureAccess(forPath: newPath, rootID: root.id, catalog: catalog) }
        return result
    }
}

// MARK: - Relink engine
//
// Relinking a root (drive / folder) to a DIFFERENT path: the drive was renamed, or the catalog
// came from another Mac where it is mounted elsewhere. Paths are compared with
// `Catalog.normalizedPath` everywhere. UI: `RootsAccessView` (Relink…).

/// Result of sampling a root's photos under a candidate folder.
nonisolated struct RelinkCheck: Sendable, Equatable {
    /// Photos of the root in the catalog.
    var photoCount: Int
    var sampled: Int
    var found: Int
    /// A few sampled photo paths (new location) that don't exist.
    var missingExamples: [String]

    var fraction: Double { sampled > 0 ? Double(found) / Double(sampled) : 0 }
    /// At least 80% of the sample exists at the same relative paths.
    var looksRight: Bool { sampled > 0 && fraction >= 0.8 }
}

nonisolated struct RelinkResult: Sendable, Equatable {
    var rootID: Int64
    var oldPath: String
    var newPath: String
    var photoIDs: [Int64]
    var sidecarsRewritten: Int
}

nonisolated enum RelinkError: Error, CustomStringConvertible, LocalizedError {
    case rootNotFound
    case pathInUse(String)
    case photoConflicts(Int, example: String)

    var description: String {
        switch self {
        case .rootNotFound: "That drive is no longer in the catalog."
        case .pathInUse(let p): "“\(p)” is already a separate drive/folder in the catalog. Use Grant Access… on that one instead."
        case .photoConflicts(let n, let example):
            "\(n) photos already exist in the catalog at the new location (e.g. “\(example)”), so the drive can't be relinked there."
        }
    }
    var errorDescription: String? { description }
}

nonisolated extension Catalog {
    /// Photos that belong to `root`: under its path and not under a more specific root.
    /// Returns (id, path, sidecar path).
    func photoPaths(of root: Root) throws -> [(id: Int64, path: String, sidecar: String?)] {
        let roots = try allRoots()
        let rootPath = Self.normalizedPath(root.path)
        let rows = try db.query("SELECT id, path, sidecar_path FROM photos") { ($0.int(0), $0.string(1), $0.stringOrNil(2)) }
        return rows.compactMap { row in
            guard Self.path(row.1, isUnderRoot: rootPath),
                  Self.coveringRoot(for: row.1, in: roots)?.id == root.id else { return nil }
            return (id: row.0, path: row.1, sidecar: row.2)
        }
    }

    /// `path` (under `oldRoot`) moved under `newRoot` with the same relative path.
    static func relinkedPath(_ path: String, from oldRoot: String, to newRoot: String) -> String {
        let p = normalizedPath(path), old = normalizedPath(oldRoot), new = normalizedPath(newRoot)
        var relative = p == old ? "" : String(p.dropFirst(old == "/" ? 1 : old.count + 1))
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { return new }
        return new == "/" ? "/" + relative : new + "/" + relative
    }

    /// Checks whether `newPath` holds the root's photos: samples up to `sampleSize` photos (evenly
    /// spread) and tests their files at the same relative paths. Call off the main thread with
    /// access to `newPath` (right after the open panel returned it).
    func relinkCheck(root: Root, newPath: String, sampleSize: Int = 200,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> RelinkCheck {
        let photos = try photoPaths(of: root)
        guard !photos.isEmpty else { return RelinkCheck(photoCount: 0, sampled: 0, found: 0, missingExamples: []) }
        let n = min(sampleSize, photos.count)
        var found = 0
        var missing: [String] = []
        for i in 0..<n {
            let photo = photos[i * photos.count / n]
            let candidate = Self.relinkedPath(photo.path, from: root.path, to: newPath)
            if fileExists(candidate) { found += 1 } else if missing.count < 5 { missing.append(candidate) }
        }
        return RelinkCheck(photoCount: photos.count, sampled: n, found: found, missingExamples: missing)
    }

    /// In one transaction: sets the root's path (+ bookmark / display name) to `newPath` and
    /// rewrites every photo (and sidecar) path under the old root to the new prefix. Posts `.roots`.
    @discardableResult
    func relinkRoot(id: Int64, to newPath: String, bookmark: Data?, displayName: String? = nil) throws -> RelinkResult {
        let newRootPath = Self.normalizedPath(newPath)
        let result: RelinkResult = try db.transaction {
            guard let root = try root(id: id) else { throw RelinkError.rootNotFound }
            let oldRootPath = Self.normalizedPath(root.path)
            if let other = try allRoots().first(where: { $0.path == newRootPath && $0.id != id }) {
                throw RelinkError.pathInUse(other.path)
            }
            let photos = try photoPaths(of: root)
            let moving = Set(photos.map(\.id))
            let targets = photos.map { (id: $0.id, path: Self.relinkedPath($0.path, from: oldRootPath, to: newRootPath)) }
            // A photo outside this root already at a target path would violate UNIQUE(path).
            let others = Set(try db.query("SELECT id, path FROM photos") { ($0.int(0), $0.string(1)) }
                .filter { !moving.contains($0.0) }.map { Self.normalizedPath($0.1) })
            let conflicts = targets.filter { others.contains($0.path) }
            if let first = conflicts.first { throw RelinkError.photoConflicts(conflicts.count, example: first.path) }

            try db.run("UPDATE roots SET path = ?, bookmark = ?, display_name = COALESCE(?, display_name) WHERE id = ?",
                       [newRootPath, bookmark, displayName, id])
            // Two phases, so old and new paths may overlap (e.g. relinking to a parent folder).
            for photo in photos {
                try db.run("UPDATE photos SET path = ? WHERE id = ?", ["\u{1}relink:\(photo.id)", photo.id])
            }
            var sidecars = 0
            for (photo, target) in zip(photos, targets) {
                var sidecar = photo.sidecar
                if let s = sidecar, Self.path(s, isUnderRoot: oldRootPath) {
                    sidecar = Self.relinkedPath(s, from: oldRootPath, to: newRootPath)
                    sidecars += 1
                }
                try db.run("UPDATE photos SET path = ?, sidecar_path = ?, root_id = ? WHERE id = ?",
                           [target.path, sidecar, id, photo.id])
            }
            return RelinkResult(rootID: id, oldPath: oldRootPath, newPath: newRootPath,
                                photoIDs: photos.map(\.id), sidecarsRewritten: sidecars)
        }
        postChange(.roots)
        return result
    }
}
