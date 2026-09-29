//
//  PreviewDiskCache.swift
//  sloproom
//
//  JPEG previews on disk: `<catalogDirectory>/Previews/<shard>/<id>_<level>_v<editVersion>_<signature>.jpg`
//  with shard = two hex digits of the photo id (≈ 80 photos per directory at 20k photos).
//  Writing a new version of (photo, level) deletes the older ones. A file's modification date is
//  its "last used" date (touched once per session on read) for LRU pruning.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated final class PreviewDiskCache: @unchecked Sendable {
    let directory: URL

    private let lock = NSLock()
    /// Files whose modification date was already refreshed this session.
    private var touched: Set<String> = []
    /// Approximate bytes on disk (nil until the first scan).
    private var usage: Int64?
    private var isPruning = false
    private let fm = FileManager.default

    init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Names

    static func levelCode(_ level: PreviewLevel) -> String {
        switch level {
        case .thumbnail: "t"
        case .standard: "s"
        }
    }

    static func fileName(photoID: Int64, level: PreviewLevel, editVersion: Int, signature: String) -> String {
        "\(photoID)_\(levelCode(level))_v\(editVersion)_\(signature).jpg"
    }

    private func shardURL(_ photoID: Int64) -> URL {
        directory.appendingPathComponent(String(format: "%02x", UInt8(truncatingIfNeeded: photoID)), isDirectory: true)
    }

    func url(photoID: Int64, name: String) -> URL {
        shardURL(photoID).appendingPathComponent(name, isDirectory: false)
    }

    /// All cached files of a photo (optionally one level), any version.
    private func files(photoID: Int64, level: PreviewLevel? = nil) -> [URL] {
        let prefix = level.map { "\(photoID)_\(Self.levelCode($0))_" } ?? "\(photoID)_"
        let shard = shardURL(photoID)
        guard let names = try? fm.contentsOfDirectory(atPath: shard.path) else { return [] }
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }
            .map { shard.appendingPathComponent($0, isDirectory: false) }
    }

    // MARK: - Read

    func exists(photoID: Int64, name: String) -> Bool {
        fm.fileExists(atPath: url(photoID: photoID, name: name).path)
    }

    /// Decodes a cached preview (fully, on the calling thread). nil on miss.
    func read(photoID: Int64, name: String) -> CGImage? {
        let url = url(photoID: photoID, name: name)
        guard let image = Self.decode(url: url, maxPixelSize: nil) else { return nil }
        touch(url)
        return image
    }

    /// Downsampled decode of a cached preview (e.g. a thumbnail from a standard preview).
    func read(photoID: Int64, name: String, maxPixelSize: Int) -> CGImage? {
        Self.decode(url: url(photoID: photoID, name: name), maxPixelSize: maxPixelSize)
    }

    /// Newest cached version of (photo, level), whatever its edit version / settings. Used when the
    /// original is offline: an older preview beats a blank cell.
    func readAnyVersion(photoID: Int64, level: PreviewLevel) -> CGImage? {
        let newest = files(photoID: photoID, level: level)
            .max { modificationDate($0) < modificationDate($1) }
        return newest.flatMap { Self.decode(url: $0, maxPixelSize: nil) }
    }

    func hasAnyVersion(photoID: Int64, level: PreviewLevel) -> Bool {
        !files(photoID: photoID, level: level).isEmpty
    }

    static func decode(url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let maxPixelSize {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Write

    /// Writes atomically (temp file + rename) and removes older versions of (photo, level).
    @discardableResult
    func write(_ image: CGImage, photoID: Int64, level: PreviewLevel, name: String, quality: Double) -> Bool {
        let shard = shardURL(photoID)
        try? fm.createDirectory(at: shard, withIntermediateDirectories: true)
        let final = shard.appendingPathComponent(name, isDirectory: false)
        let temp = shard.appendingPathComponent(".\(name).\(UUID().uuidString).tmp", isDirectory: false)
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), rename(temp.path, final.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        var delta = fileSize(final)
        for old in files(photoID: photoID, level: level) where old.lastPathComponent != name {
            delta -= fileSize(old)
            try? fm.removeItem(at: old)
        }
        lock.lock()
        if usage != nil { usage! += delta }
        touched.insert(final.path)
        lock.unlock()
        return true
    }

    // MARK: - Remove

    func remove(photoIDs: some Sequence<Int64>) {
        var freed: Int64 = 0
        for id in photoIDs {
            for url in files(photoID: id) {
                freed += fileSize(url)
                try? fm.removeItem(at: url)
            }
        }
        lock.lock()
        if usage != nil { usage! -= freed }
        lock.unlock()
    }

    func removeAll() {
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        lock.lock()
        usage = 0
        touched.removeAll()
        lock.unlock()
    }

    // MARK: - Size / pruning

    /// Exact bytes on disk (scans the directory; call off the main thread).
    func computeUsage() -> Int64 {
        let total = scan().reduce(Int64(0)) { $0 + $1.size }
        lock.lock(); usage = total; lock.unlock()
        return total
    }

    /// Last known (approximate) usage, nil before the first scan.
    var approximateUsage: Int64? {
        lock.lock(); defer { lock.unlock() }
        return usage
    }

    /// Deletes least recently used files until usage <= 90 % of `maxBytes`. Returns bytes freed.
    @discardableResult
    func prune(maxBytes: Int64) -> Int64 {
        lock.lock()
        if isPruning { lock.unlock(); return 0 }
        isPruning = true
        lock.unlock()
        defer { lock.lock(); isPruning = false; lock.unlock() }

        var entries = scan()
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        var freed: Int64 = 0
        if total > maxBytes {
            let target = maxBytes / 10 * 9
            entries.sort { $0.date < $1.date }
            for e in entries {
                if total <= target { break }
                if (try? fm.removeItem(at: e.url)) != nil {
                    total -= e.size
                    freed += e.size
                }
            }
        }
        lock.lock(); usage = total; lock.unlock()
        return freed
    }

    private struct Entry { let url: URL; let size: Int64; let date: Date }

    private func scan() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [Entry] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(Entry(url: url, size: Int64(v.fileSize ?? 0), date: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    // MARK: - Helpers

    /// Marks a file as recently used (once per session per file).
    private func touch(_ url: URL) {
        lock.lock()
        let first = touched.insert(url.path).inserted
        lock.unlock()
        if first { utimes(url.path, nil) }
    }

    private func fileSize(_ url: URL) -> Int64 {
        var st = stat()
        return stat(url.path, &st) == 0 ? Int64(st.st_size) : 0
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
