//
//  RootAccess.swift
//  sloproom
//
//  Online / offline / access-granted status of roots, and granting access to a root by picking
//  it (or one of its parent folders, e.g. the whole drive) in an open panel. Engine part of
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
}
