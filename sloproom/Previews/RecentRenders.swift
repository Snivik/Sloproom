//
//  RecentRenders.swift
//  sloproom
//
//  "Recent renders": the last N full-quality Develop renders (default 100, Settings > Previews,
//  0 disables), so going back to a photo shows a sharp image instantly instead of re-reading and
//  re-decoding the RAW from an external drive.
//
//  - Disk: `<catalogDirectory>/Previews/Recent/<photoID>_<settingsHash>_<boxW>x<boxH>.jpg`
//    (JPEG q 0.9, Display P3, the rendered size), at most ONE file per photo (a new
//    render replaces the old one). The file's modification date is its "last used" date; beyond
//    N photos the least recently used are deleted.
//  - Memory: LRU of decoded images (≤ `memoryCountLimit` entries / `memoryByteLimit` bytes).
//  - Key: photo id + hash of (EditSettings JSON, pipeline/build version) + the pixel box the render
//    was fitted to (the canvas size). Edits change the hash, so an entry is only returned for the
//    exact settings it shows; stale entries are dropped when found (lookup, `dropStale`).
//    Only crop-applied renders are stored (the Develop canvas opens with the crop applied).
//  - Writes are asynchronous, coalesced per photo (a slider drag writes once, after it settles).
//  - `Recent/.build` records the build that wrote the renders; another build deletes them all.
//
//  Thread-safe; lookups from memory never block on IO. Engine file (no SwiftUI/AppKit).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What a recent render shows. `box` is the pixel size the render was fitted into.
nonisolated struct RecentRenderKey: Hashable, Sendable {
    let photoID: Int64
    let settingsHash: UInt64
    let boxWidth: Int
    let boxHeight: Int

    init(photoID: Int64, settingsHash: UInt64, box: CGSize) {
        self.photoID = photoID
        self.settingsHash = settingsHash
        self.boxWidth = Int(box.width.rounded())
        self.boxHeight = Int(box.height.rounded())
    }

    var box: CGSize { CGSize(width: boxWidth, height: boxHeight) }

    var fileName: String {
        "\(photoID)_\(String(settingsHash, radix: 16))_\(boxWidth)x\(boxHeight).\(RecentRenders.fileExtension)"
    }

    /// Parses `fileName` (nil for foreign files).
    init?(fileName: String) {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_")
        guard parts.count == 3, let id = Int64(parts[0]), let hash = UInt64(parts[1], radix: 16) else { return nil }
        let wh = parts[2].split(separator: "x")
        guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { return nil }
        photoID = id; settingsHash = hash; boxWidth = w; boxHeight = h
    }

    /// Hash of everything that decides how a render looks apart from its size: the edit settings
    /// and the app build (a rebuilt render pipeline may render differently).
    static func settingsHash(_ settings: EditSettings) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        mix(RecentRenders.buildSignature)
        mix("|")
        mix(settings.jsonString() ?? "")
        return h
    }
}

/// A recent render found in the cache.
nonisolated struct RecentRender: @unchecked Sendable {
    let image: CGImage
    let key: RecentRenderKey
}

nonisolated final class RecentRenders: @unchecked Sendable {
    static let shared = RecentRenders()

    static let defaultLimit = 100
    static let maxLimit = 2000
    /// Longest edge stored on disk (the in-memory image keeps its full size).
    static let maxStoredPixelSize = 3200
    /// JPEG q 0.9: at a 2250×1500 canvas render ≈ 0.5 MB, encode ≈ 11 ms, decode ≈ 7 ms.
    /// (HEIC is ≈ 25 % smaller but decodes in 35–85 ms, too slow for "instant".)
    static let fileExtension = "jpg"
    static let fileType = UTType.jpeg

    /// Identifies the running build (version + executable date): renders made by another build
    /// are not reused, since the pipeline may have changed.
    static let buildSignature: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "")-\(info["CFBundleVersion"] ?? "")"
        var date = 0
        if let exe = Bundle.main.executableURL,
           let d = try? exe.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            date = Int(d.timeIntervalSince1970)
        }
        return "rr1-\(version)-\(date)"
    }()

    // Configuration
    private let lock = NSLock()
    private var _directory: URL?
    private var _limit = RecentRenders.defaultLimit
    /// Decoded renders kept in memory (a Retina canvas render is ≈ 10–20 MB).
    let memoryCountLimit = 16
    let memoryByteLimit = 400 * 1024 * 1024

    // Disk index (photo id → newest file), loaded lazily.
    private struct DiskEntry { var key: RecentRenderKey; var url: URL; var size: Int64; var lastUsed: Date }
    private var index: [Int64: DiskEntry] = [:]
    private var indexLoaded = false

    // Memory LRU (most recent last).
    private struct MemoryEntry { let render: RecentRender; let cost: Int }
    private var memory: [Int64: MemoryEntry] = [:]
    private var memoryOrder: [Int64] = []
    private var memoryBytes = 0

    // Pending writes, coalesced per photo.
    private var pending: [Int64: RecentRender] = [:]
    private let writeQueue = DispatchQueue(label: "Sloproom.RecentRenders.write", qos: .utility)
    private let readQueue = DispatchQueue(label: "Sloproom.RecentRenders.read", qos: .userInitiated, attributes: .concurrent)
    private var inFlightReads: Set<Int64> = []
    private let fm = FileManager.default

    private var terminationObserver: NSObjectProtocol?
    /// Bumped by `purgeAll()`; writes that started before are dropped.
    private var epoch = 0
    private var currentEpoch: Int { lock.lock(); defer { lock.unlock() }; return epoch }

    // Statistics
    nonisolated struct Stats: Sendable {
        var memoryHits = 0, diskHits = 0, misses = 0, staleDropped = 0, stores = 0, writes = 0, evictions = 0, prefetches = 0
        var lastDiskReadMs = 0.0, lastWriteMs = 0.0
    }
    private var _stats = Stats()

    // MARK: - Configuration

    /// `directory` = `<catalogDirectory>/Previews/Recent`. Called by `PreviewService.configure`.
    func configure(directory: URL, limit: Int) {
        lock.lock()
        _directory = directory
        _limit = max(0, limit)
        index = [:]
        indexLoaded = false
        memory = [:]; memoryOrder = []; memoryBytes = 0
        pending = [:]
        if terminationObserver == nil {
            // Write renders still waiting for their coalescing delay before the app quits
            // (AppKit's willTerminate notification, by name: engine files don't import AppKit).
            terminationObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            }
        }
        lock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.loadIndexLocked(); self.lock.unlock()
            self.evictIfNeeded()
        }
    }

    var directory: URL? {
        lock.lock(); defer { lock.unlock() }
        return _directory
    }

    /// Number of photos kept (0 = disabled). Lowering it evicts immediately.
    var limit: Int {
        get { lock.lock(); defer { lock.unlock() }; return _limit }
        set {
            lock.lock(); _limit = max(0, min(newValue, Self.maxLimit)); lock.unlock()
            writeQueue.async { [weak self] in self?.evictIfNeeded() }
        }
    }

    var isEnabled: Bool { limit > 0 }

    // MARK: - Lookup

    /// Memory hit only (never blocks on IO). Drops a stale entry of that photo.
    func memoryRender(photoID: Int64, settingsHash: UInt64) -> RecentRender? {
        lock.lock(); defer { lock.unlock() }
        guard _limit > 0, let e = memory[photoID] else { return nil }
        guard e.render.key.settingsHash == settingsHash else { removeMemoryLocked(photoID); return nil }
        touchMemoryLocked(photoID)
        markUsedLocked(photoID)
        _stats.memoryHits += 1
        return e.render
    }

    /// Whether a render of these settings exists (memory or disk). Cheap, no IO.
    func contains(photoID: Int64, settingsHash: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _limit > 0 else { return false }
        if memory[photoID]?.render.key.settingsHash == settingsHash { return true }
        loadIndexLocked()
        return index[photoID]?.key.settingsHash == settingsHash
    }

    /// Memory, then disk (decodes on the calling thread; call off-main). The result is kept in memory.
    func render(photoID: Int64, settingsHash: UInt64) -> RecentRender? {
        if let hit = memoryRender(photoID: photoID, settingsHash: settingsHash) { return hit }
        lock.lock()
        guard _limit > 0 else { lock.unlock(); return nil }
        loadIndexLocked()
        guard let entry = index[photoID] else { _stats.misses += 1; lock.unlock(); return nil }
        guard entry.key.settingsHash == settingsHash else {
            // The photo was edited since: this render is stale.
            index[photoID] = nil
            _stats.staleDropped += 1
            _stats.misses += 1
            lock.unlock()
            try? fm.removeItem(at: entry.url)
            return nil
        }
        lock.unlock()

        let t = Date()
        guard let image = Self.decode(url: entry.url) else {
            lock.lock(); index[photoID] = nil; _stats.misses += 1; lock.unlock()
            try? fm.removeItem(at: entry.url)
            return nil
        }
        let render = RecentRender(image: image, key: entry.key)
        let now = Date()
        utimes(entry.url.path, nil)
        lock.lock()
        _stats.diskHits += 1
        _stats.lastDiskReadMs = now.timeIntervalSince(t) * 1000
        index[photoID]?.lastUsed = now
        // Don't replace a newer in-memory render (stored while we were decoding).
        if memory[photoID] == nil { insertMemoryLocked(render) }
        lock.unlock()
        return render
    }

    /// Async disk lookup on a background queue; `completion` runs on that queue.
    func loadRender(photoID: Int64, settingsHash: UInt64, completion: @escaping @Sendable (RecentRender?) -> Void) {
        readQueue.async { [weak self] in completion(self?.render(photoID: photoID, settingsHash: settingsHash)) }
    }

    /// Warms memory with the photo's render if one exists on disk (low priority, deduplicated).
    /// Returns false if there is no render for these settings (caller may warm something else).
    @discardableResult
    func prefetch(photoID: Int64, settingsHash: UInt64) -> Bool {
        lock.lock()
        guard _limit > 0 else { lock.unlock(); return false }
        if memory[photoID]?.render.key.settingsHash == settingsHash { lock.unlock(); return true }
        loadIndexLocked()
        guard index[photoID]?.key.settingsHash == settingsHash else { lock.unlock(); return false }
        guard inFlightReads.insert(photoID).inserted else { lock.unlock(); return true }
        _stats.prefetches += 1
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = self.render(photoID: photoID, settingsHash: settingsHash)
            self.lock.lock(); self.inFlightReads.remove(photoID); self.lock.unlock()
        }
        return true
    }

    // MARK: - Store

    /// Remembers a finished full-quality render (memory now, disk shortly after, coalesced).
    func store(_ image: CGImage, key: RecentRenderKey) {
        let render = RecentRender(image: image, key: key)
        lock.lock()
        guard _limit > 0, _directory != nil else { lock.unlock(); return }
        _stats.stores += 1
        insertMemoryLocked(render)
        let stored = index[key.photoID]?.key
        let alreadyOnDisk = stored == key || (stored?.settingsHash == key.settingsHash && stored?.boxWidth == 0
            && max(image.width, image.height) > Self.maxStoredPixelSize)
        if alreadyOnDisk { // just mark as used
            index[key.photoID]?.lastUsed = Date()
            let url = index[key.photoID]!.url
            lock.unlock()
            writeQueue.async { utimes(url.path, nil) }
            return
        }
        let isFirst = pending[key.photoID] == nil
        pending[key.photoID] = render
        lock.unlock()
        if isFirst {
            writeQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.writePending(photoID: key.photoID) }
        }
    }

    /// Writes all pending renders now (e.g. before quitting). Blocks until done.
    func flush() {
        lock.lock()
        let ids = Array(pending.keys)
        lock.unlock()
        writeQueue.sync { for id in ids { writePending(photoID: id) } }
    }

    private func writePending(photoID: Int64) {
        lock.lock()
        guard let render = pending.removeValue(forKey: photoID), let dir = _directory, _limit > 0 else { lock.unlock(); return }
        loadIndexLocked()
        let old = index[photoID]
        let epoch = self.epoch
        lock.unlock()

        let t = Date()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(render.key.fileName, isDirectory: false)
        let temp = dir.appendingPathComponent(".\(render.key.fileName).\(UUID().uuidString).tmp", isDirectory: false)
        var image = render.image
        var key = render.key
        if max(image.width, image.height) > Self.maxStoredPixelSize, let small = Self.downscale(image, to: Self.maxStoredPixelSize) {
            image = small
            key = RecentRenderKey(photoID: key.photoID, settingsHash: key.settingsHash, box: .zero) // never an exact match
        }
        let finalURL = key == render.key ? url : dir.appendingPathComponent(key.fileName, isDirectory: false)
        guard Self.encode(image, to: temp), currentEpoch == epoch, rename(temp.path, finalURL.path) == 0 else {
            try? fm.removeItem(at: temp) // failed, or purged meanwhile (catalog replaced)
            return
        }
        if let old, old.url != finalURL { try? fm.removeItem(at: old.url) }
        let size = Self.fileSize(finalURL)
        lock.lock()
        guard self.epoch == epoch else { lock.unlock(); try? fm.removeItem(at: finalURL); return }
        index[photoID] = DiskEntry(key: key, url: finalURL, size: size, lastUsed: Date())
        _stats.writes += 1
        _stats.lastWriteMs = Date().timeIntervalSince(t) * 1000
        lock.unlock()
        evictIfNeeded()
    }

    // MARK: - Invalidation

    /// Deletes renders of these photos (memory + disk).
    func remove(photoIDs: some Collection<Int64>) {
        lock.lock()
        loadIndexLocked()
        var urls: [URL] = []
        for id in photoIDs {
            removeMemoryLocked(id)
            pending[id] = nil
            if let e = index.removeValue(forKey: id) { urls.append(e.url) }
        }
        lock.unlock()
        for url in urls { try? fm.removeItem(at: url) }
    }

    /// Drops renders that no longer match the photos' saved settings (after edits elsewhere,
    /// e.g. Paste Settings in Library). `photos`: (id, current settings hash).
    func dropStale(_ photos: [(id: Int64, settingsHash: UInt64)]) {
        lock.lock()
        loadIndexLocked()
        var urls: [URL] = []
        for p in photos {
            if let m = memory[p.id], m.render.key.settingsHash != p.settingsHash { removeMemoryLocked(p.id) }
            if let e = index[p.id], e.key.settingsHash != p.settingsHash {
                index[p.id] = nil
                urls.append(e.url)
                _stats.staleDropped += 1
            }
        }
        lock.unlock()
        for url in urls { try? fm.removeItem(at: url) }
    }

    /// Deletes everything ("Clean Cache").
    func removeAll() {
        lock.lock()
        memory = [:]; memoryOrder = []; memoryBytes = 0
        pending = [:]
        index = [:]
        indexLoaded = true
        let dir = _directory
        lock.unlock()
        if let dir, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent != ".build" { try? fm.removeItem(at: item) }
        }
    }

    /// Forgets all in-memory state (memory LRU, pending writes, disk index, prefetch state)
    /// without touching files. For replacing the catalog in-process: photo ids of the old catalog
    /// mean nothing in the new one. The disk index is re-read from the directory on next use (the
    /// caller deletes `<catalogDirectory>/Previews/`, which contains `Recent/`). Waits for a write
    /// in flight; a write that started before the purge is discarded.
    func purgeAll() {
        lock.lock()
        epoch += 1
        memory = [:]; memoryOrder = []; memoryBytes = 0
        pending = [:]
        index = [:]
        indexLoaded = false
        inFlightReads = []
        lock.unlock()
        writeQueue.sync {}
        RecentRendersPrefetch.shared.reset()
    }

    /// Drops decoded images from memory only.
    func purgeMemory() {
        lock.lock(); memory = [:]; memoryOrder = []; memoryBytes = 0; lock.unlock()
    }

    // MARK: - Size

    /// (photos on disk, bytes on disk).
    var diskUsage: (count: Int, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        loadIndexLocked()
        return (index.count, index.values.reduce(0) { $0 + $1.size })
    }

    // MARK: - Statistics

    var stats: Stats { lock.lock(); defer { lock.unlock() }; return _stats }
    func resetStats() { lock.lock(); _stats = Stats(); lock.unlock() }

    var statsDescription: String {
        let s = stats
        return "memoryHits=\(s.memoryHits) diskHits=\(s.diskHits) misses=\(s.misses) stale=\(s.staleDropped) stores=\(s.stores) "
            + "writes=\(s.writes) evictions=\(s.evictions) prefetches=\(s.prefetches) "
            + String(format: "lastDiskRead=%.1fms lastWrite=%.1fms", s.lastDiskReadMs, s.lastWriteMs)
    }

    var debugDescription: String {
        let usage = diskUsage
        lock.lock(); defer { lock.unlock() }
        return "limit=\(_limit) disk=\(usage.count) photos \(usage.bytes / 1024) KB, memory=\(memory.count) (\(memoryBytes / 1_048_576) MB) ids=\(memoryOrder) pending=\(pending.count) format=\(Self.fileExtension)"
    }

    // MARK: - Internals (lock held)

    private func loadIndexLocked() {
        guard !indexLoaded, let dir = _directory else { return }
        indexLoaded = true
        // Renders of another build can never match (the build is part of every key): delete them.
        let marker = dir.appendingPathComponent(".build", isDirectory: false)
        if (try? String(contentsOf: marker, encoding: .utf8)) != Self.buildSignature {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items { try? fm.removeItem(at: item) }
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Self.buildSignature.write(to: marker, atomically: true, encoding: .utf8)
            return
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for url in urls {
            guard let key = RecentRenderKey(fileName: url.lastPathComponent) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let entry = DiskEntry(key: key, url: url, size: Int64(v?.fileSize ?? 0), lastUsed: v?.contentModificationDate ?? .distantPast)
            if let existing = index[key.photoID] { // two files of one photo (crash mid-write): keep the newest
                let (keep, drop) = existing.lastUsed >= entry.lastUsed ? (existing, entry) : (entry, existing)
                index[key.photoID] = keep
                try? fm.removeItem(at: drop.url)
            } else {
                index[key.photoID] = entry
            }
        }
    }

    private func evictIfNeeded() {
        lock.lock()
        loadIndexLocked()
        let limit = _limit
        var victims: [URL] = []
        if index.count > limit {
            let sorted = index.values.sorted { $0.lastUsed < $1.lastUsed }
            for e in sorted.prefix(index.count - limit) {
                index[e.key.photoID] = nil
                victims.append(e.url)
            }
            _stats.evictions += victims.count
        }
        trimMemoryLocked()
        if limit == 0 { pending = [:] }
        lock.unlock()
        for url in victims { try? fm.removeItem(at: url) }
    }

    private func insertMemoryLocked(_ render: RecentRender) {
        removeMemoryLocked(render.key.photoID)
        let cost = render.image.bytesPerRow * render.image.height
        memory[render.key.photoID] = MemoryEntry(render: render, cost: cost)
        memoryOrder.append(render.key.photoID)
        memoryBytes += cost
        trimMemoryLocked()
    }

    /// At most `memoryCountLimit` (and never more than N) entries / `memoryByteLimit` bytes.
    private func trimMemoryLocked() {
        let maxCount = min(memoryCountLimit, _limit)
        while !memoryOrder.isEmpty, memoryOrder.count > maxCount || (memoryOrder.count > 1 && memoryBytes > memoryByteLimit) {
            removeMemoryLocked(memoryOrder[0])
        }
    }

    /// Refreshes the disk entry's "last used" date (LRU), also on memory hits.
    private func markUsedLocked(_ id: Int64) {
        guard let e = index[id] else { return }
        let now = Date()
        guard now.timeIntervalSince(e.lastUsed) > 5 else { return }
        index[id]?.lastUsed = now
        writeQueue.async { utimes(e.url.path, nil) }
    }

    private func removeMemoryLocked(_ id: Int64) {
        guard let e = memory.removeValue(forKey: id) else { return }
        memoryBytes -= e.cost
        memoryOrder.removeAll { $0 == id }
    }

    private func touchMemoryLocked(_ id: Int64) {
        guard let i = memoryOrder.firstIndex(of: id) else { return }
        memoryOrder.remove(at: i)
        memoryOrder.append(id)
    }

    // MARK: - ImageIO

    static func encode(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, fileType.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Fully decoded (drawing it never decodes on the main thread).
    static func decode(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func downscale(_ image: CGImage, to maxPixelSize: Int) -> CGImage? {
        let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func fileSize(_ url: URL) -> Int64 {
        var st = stat()
        return stat(url.path, &st) == 0 ? Int64(st.st_size) : 0
    }
}
