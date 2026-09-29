//
//  ImportSources.swift
//  sloproom
//
//  Import sources: mounted camera cards / removable volumes, plus remembered folder grants.
//  Sandbox: listing /Volumes works, but reading a card needs a user grant (NSOpenPanel) once;
//  we keep a security-scoped bookmark per volume (keyed by volume UUID, so a different card with
//  the same name asks again) in UserDefaults. Sources are NOT catalog roots (photos get copied
//  off them) — only "Add in Place" registers the source as a root.
//

import Foundation

nonisolated struct ImportVolume: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var uuid: String?
    /// Has a DCIM folder (only detectable once access was granted, or outside the sandbox).
    var hasDCIM: Bool
    var id: String { url.path }
    var bookmarkKey: String { "volume:" + (uuid ?? url.path) }
}

/// A remembered, user-granted source folder.
nonisolated struct RecentImportFolder: Hashable, Sendable {
    var name: String
    var path: String
    var key: String
}

nonisolated enum ImportSources {
    private static let bookmarksKey = "import.sourceBookmarks"
    private static let recentKey = "import.recentFolder"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var accessing: [String: URL] = [:]

    /// Mounted removable / ejectable volumes and anything with a DCIM folder; cards first.
    static func volumes() -> [ImportVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
                                      .volumeIsEjectableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let stored = storedBookmarks()
        let result: [ImportVolume] = urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.volumeIsRootFileSystem == true || url.path == "/" { return nil }
            var volume = ImportVolume(url: url, name: v?.volumeName ?? url.lastPathComponent, uuid: v?.volumeUUIDString, hasDCIM: false)
            if let granted = stored[volume.bookmarkKey].flatMap(resolve) {
                volume.hasDCIM = hasDCIM(granted) || hasDCIM(url)
            } else {
                volume.hasDCIM = hasDCIM(url)
            }
            let removable = v?.volumeIsRemovable == true || v?.volumeIsEjectable == true
            return removable || volume.hasDCIM ? volume : nil
        }
        return result.sorted { ($0.hasDCIM ? 0 : 1, $0.name) < ($1.hasDCIM ? 0 : 1, $1.name) }
    }

    static func hasDCIM(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Previously granted URL for `key`, with its security scope started. nil = ask the user.
    static func grantedURL(forKey key: String) -> URL? {
        storedBookmarks()[key].flatMap(resolve)
    }

    /// Remembers access to `url` (call right after NSOpenPanel returns it) under `key`.
    static func remember(_ url: URL, key: String) {
        guard let data = try? SecurityScope.makeBookmark(for: url) else { return }
        var all = storedBookmarks()
        all[key] = data
        UserDefaults.standard.set(all, forKey: bookmarksKey)
        _ = resolve(data) // start the scope now so the grant survives the panel
    }

    /// Key for a picked folder: its volume's key when the folder is the volume itself.
    static func key(forPickedFolder url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
        if let vol = v?.volume, vol.standardizedFileURL.path == url.standardizedFileURL.path {
            return "volume:" + (v?.volumeUUIDString ?? vol.path)
        }
        return "folder:" + url.standardizedFileURL.path
    }

    static var recentFolder: RecentImportFolder? {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: recentKey) as? [String: String],
                  let name = d["name"], let path = d["path"], let key = d["key"] else { return nil }
            return RecentImportFolder(name: name, path: path, key: key)
        }
        set {
            if let f = newValue {
                UserDefaults.standard.set(["name": f.name, "path": f.path, "key": f.key], forKey: recentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: recentKey)
            }
        }
    }

    // MARK: - Private

    private static func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }

    /// Resolves a bookmark and starts (once, for the app's lifetime) its security scope.
    private static func resolve(_ data: Data) -> URL? {
        guard let resolved = try? SecurityScope.resolveBookmark(data) else { return nil }
        let url = resolved.url
        lock.lock(); defer { lock.unlock() }
        if let active = accessing[url.path] { return active }
        let started = url.startAccessingSecurityScopedResource() // false outside the sandbox; access still works
        guard FileManager.default.fileExists(atPath: url.path) else { // e.g. card not mounted
            if started { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        accessing[url.path] = url
        return url
    }
}
