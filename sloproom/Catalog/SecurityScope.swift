//
//  SecurityScope.swift
//  sloproom
//
//  Sandbox file access. The app is sandboxed: it can only read files the user granted via an
//  open panel / drag & drop. We persist those grants as security-scoped bookmarks on `roots`
//  (a folder or volume). Before reading ANY photo file, go through `SecurityScopeManager`
//  so the covering root's scope is started (once; kept open for the app's lifetime).
//
//  Typical flow:
//    // after NSOpenPanel returns `url` (implicit access still valid):
//    let root = try SecurityScopeManager.shared.registerRoot(url: url, in: catalog)
//    // later, anywhere, any thread:
//    let fileURL = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
//

import Foundation

nonisolated enum SecurityScope {
    /// Creates security-scoped bookmark data for a URL the process currently has access to.
    /// Tries a read/write bookmark first and falls back to read-only (the app currently has the
    /// read-only user-selected-files entitlement).
    static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    /// Resolves bookmark data. `isStale == true` means the caller should re-create and store a new
    /// bookmark (while accessing the resolved URL).
    static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    /// Convenience for `SecurityScopeManager.shared.withAccess`.
    static func withAccess<T>(to url: URL, catalog: Catalog, _ body: (URL) throws -> T) rethrows -> T {
        try SecurityScopeManager.shared.withAccess(to: url, catalog: catalog, body)
    }
}

/// Starts security scopes for roots on demand and keeps them open (cached by root id).
nonisolated final class SecurityScopeManager: @unchecked Sendable {
    static let shared = SecurityScopeManager()

    private let lock = NSLock()
    /// Root id -> URL whose security scope we started.
    private var active: [Int64: URL] = [:]
    /// Roots whose bookmark failed to resolve (not retried until `reset`).
    private var failed: Set<Int64> = []

    /// Registers a user-granted directory (from NSOpenPanel / drop) as a catalog root:
    /// creates a bookmark, upserts the root and starts accessing it. Call it while the
    /// panel's implicit access is still valid (i.e. right after the panel returns).
    @discardableResult
    func registerRoot(url: URL, in catalog: Catalog, displayName: String? = nil) throws -> Root {
        let bookmark = try? SecurityScope.makeBookmark(for: url)
        let id = try catalog.upsertRoot(path: url.path, bookmark: bookmark,
                                        displayName: displayName ?? url.lastPathComponent)
        if bookmark != nil { _ = startAccess(rootID: id, catalog: catalog) }
        guard let root = try catalog.root(id: id) else { throw CatalogError.notFound }
        return root
    }

    /// Ensures the root covering `path` is being accessed. Returns false only if a covering root
    /// exists but its bookmark could not be resolved/started.
    @discardableResult
    func ensureAccess(forPath path: String, rootID: Int64? = nil, catalog: Catalog) -> Bool {
        let id: Int64?
        if let rootID { id = rootID } else { id = (try? catalog.root(for: path))?.id }
        guard let id else { return true } // no root: e.g. app container or non-sandboxed harness
        if startAccess(rootID: id, catalog: catalog) { return true }
        // A stale root id (e.g. the root was replaced by a newly granted parent folder).
        guard rootID != nil, let current = (try? catalog.root(for: path))?.id, current != id else { return false }
        return startAccess(rootID: current, catalog: catalog)
    }

    /// The photo's file URL, after making sure its root's scope is active.
    func accessibleURL(for photo: Photo, catalog: Catalog) -> URL {
        ensureAccess(forPath: photo.path, rootID: photo.rootID, catalog: catalog)
        return photo.url
    }

    /// Runs `body` with access to `url` (scope stays open afterwards; cheap to call repeatedly).
    func withAccess<T>(to url: URL, catalog: Catalog, _ body: (URL) throws -> T) rethrows -> T {
        ensureAccess(forPath: url.path, catalog: catalog)
        return try body(url)
    }

    /// Stops all scopes (e.g. before re-granting access). Rarely needed.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        for url in active.values { url.stopAccessingSecurityScopedResource() }
        active.removeAll()
        failed.removeAll()
    }

    /// Lets roots whose bookmark failed be retried (after roots changed); open scopes stay open.
    func forgetFailures() {
        lock.lock(); defer { lock.unlock() }
        failed.removeAll()
    }

    private func startAccess(rootID: Int64, catalog: Catalog) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active[rootID] != nil { return true }
        if failed.contains(rootID) { return false }
        guard let root = try? catalog.root(id: rootID), let bookmark = root.bookmark,
              let resolved = try? SecurityScope.resolveBookmark(bookmark) else {
            failed.insert(rootID)
            return false
        }
        let url = resolved.url
        guard url.startAccessingSecurityScopedResource() else {
            failed.insert(rootID)
            return false
        }
        active[rootID] = url
        if resolved.isStale, let fresh = try? SecurityScope.makeBookmark(for: url) {
            try? catalog.updateRootBookmark(id: rootID, bookmark: fresh)
        }
        return true
    }
}
