//
//  PreviewService.swift
//  sloproom
//
//  Thumbnails / standard previews for the grid, filmstrip and develop placeholder.
//  PUBLIC API (keep stable): PreviewLevel, PreviewService.shared, configure(catalog:),
//  image(for:level:), cachedImage(for:level:), invalidate(photoID:), embeddedThumbnail(url:maxPixelSize:).
//
//  Lookup: memory (NSCache, cost-limited) -> disk (`PreviewDiskCache`, JPEG) -> generate.
//  - Unedited photos: the camera's embedded JPEG via ImageIO (≈ 20 ms for a Leica DNG), unless
//    disabled in settings or too small; edited photos: rendered through `RenderPipeline`.
//  - Cache key = (photo id, edit_version, level, size/quality/source signature): saving an edit or
//    changing settings makes old previews stale; they are regenerated lazily. After an edit the
//    thumbnail of a previously previewed photo is also regenerated eagerly (background, 1 s debounce).
//  - Disk reads and generation run on two `PreviewLane`s (prioritized, coalesced, cancellable).
//  - Original offline/unreadable: fall back to any older cached preview and report `isOffline`.
//
//  Build jobs (after import, menu commands): `build(photoIDs:levels:)`, progress in `PreviewJobs.shared`.
//

import Foundation
import CoreGraphics
import ImageIO

nonisolated enum PreviewLevel: Int, Sendable, Hashable, CaseIterable {
    /// Grid / filmstrip (default 512 px long edge, see `PreviewSettings`).
    case thumbnail
    /// Loupe / develop placeholder (default 2048 px long edge).
    case standard

    /// Current long-edge size in pixels (from `PreviewSettings`).
    var maxPixelSize: Int { PreviewService.shared.settings.pixelSize(for: self) }
}

/// Outcome of a preview request.
nonisolated struct PreviewResult: Sendable {
    var image: CGImage?
    /// The original file is missing/unreadable (e.g. external drive not connected).
    /// `image` may still be set from an older cached preview.
    var isOffline = false
}

nonisolated final class PreviewService: @unchecked Sendable {
    static let shared = PreviewService()

    private let lock = NSLock()
    private var _catalog: Catalog?
    private var _disk: PreviewDiskCache?
    private var _settings = PreviewSettings.load()
    /// Bumped by `invalidate(photoID:)`; part of the memory key.
    private var generations: [Int64: Int] = [:]
    /// Bumped by `discardAll()` / settings changes; part of the memory key.
    private var epoch = 0
    private var observer: NSObjectProtocol?
    private var pendingEdited: Set<Int64> = []
    /// Photos whose last request found the original offline/unreadable (retried when roots change).
    private var offlineIDs: Set<Int64> = []
    private var editDebounce: DispatchWorkItem?

    private let cache = NSCache<NSString, CGImage>()
    /// Disk reads (fast, IO bound).
    private let ioLane = PreviewLane<CGImage?>(name: "Sloproom.Previews.io", workers: 4)
    /// Generation (embedded extraction or full render).
    private let generateLane = PreviewLane<PreviewResult>(
        name: "Sloproom.Previews.generate", workers: max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    /// Full RAW renders are memory/GPU heavy: at most this many at once.
    private let renderSlots = DispatchSemaphore(value: 2)
    private let maintenanceQueue = DispatchQueue(label: "Sloproom.Previews.maintenance", qos: .utility)
    private var writesSinceCheck = 0

    init() {
        cache.totalCostLimit = 512 * 1024 * 1024 // bytes of decoded pixels
    }

    /// Must be called once at startup (security-scoped access to photo files, disk cache location).
    func configure(catalog: Catalog) {
        let disk = PreviewDiskCache(directory: catalog.cacheDirectory("Previews"))
        lock.lock()
        _catalog = catalog
        _disk = disk
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: catalog, queue: nil) { [weak self] note in
            switch Catalog.change(from: note) {
            case .photosUpdated(let ids)?: self?.photosUpdated(ids)
            case .roots?: self?.rootsChanged()
            default: break
            }
        }
        lock.unlock()
        maintenanceQueue.async { [weak self] in self?.pruneIfNeeded() }
    }

    var catalog: Catalog? {
        lock.lock(); defer { lock.unlock() }
        return _catalog
    }

    var disk: PreviewDiskCache? {
        lock.lock(); defer { lock.unlock() }
        return _disk
    }

    /// Current settings (cached; call `reloadSettings()` after changing the UserDefaults keys).
    var settings: PreviewSettings {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    /// Re-reads `PreviewSettings` from UserDefaults. Size/quality/source changes make existing
    /// previews stale (lazy regeneration); a lower cache limit prunes.
    func reloadSettings() {
        let new = PreviewSettings.load()
        lock.lock()
        let old = _settings
        _settings = new
        let looksChanged = old.standardSize != new.standardSize || old.thumbnailSize != new.thumbnailSize
            || old.quality != new.quality || old.useEmbeddedPreviews != new.useEmbeddedPreviews
        if looksChanged { epoch += 1 }
        lock.unlock()
        if looksChanged {
            cache.removeAllObjects()
            PreviewJobs.notifyAllChanged()
        }
        if old.maxCacheGB != new.maxCacheGB { maintenanceQueue.async { [weak self] in self?.pruneIfNeeded() } }
    }

    // MARK: - Requests

    /// Memory-cache hit only; never blocks. Use to avoid a placeholder flash.
    func cachedImage(for photo: Photo, level: PreviewLevel) -> CGImage? {
        cache.object(forKey: memoryKey(photo, level) as NSString)
    }

    /// Returns a preview, generating it off the calling thread if needed. nil if unavailable.
    func image(for photo: Photo, level: PreviewLevel) async -> CGImage? {
        await load(photo, level: level, priority: .visible).image
    }

    /// Full request: memory -> disk -> generate. Cancelling the calling Task cancels the request
    /// (the result is then empty).
    func load(_ photo: Photo, level: PreviewLevel, priority: PreviewPriority = .visible) async -> PreviewResult {
        let key = memoryKey(photo, level)
        if let hit = cache.object(forKey: key as NSString) { return PreviewResult(image: hit) }
        if Task.isCancelled { return PreviewResult() }

        let s = settings
        let name = diskName(photo, level, s)
        if let disk, photo.id != 0 {
            let fromDisk = await ioLane.run(key: key, priority: priority) {
                disk.read(photoID: photo.id, name: name)
            }
            if let image = fromDisk ?? nil {
                cache.setObject(image, forKey: key as NSString, cost: Self.cost(image))
                return PreviewResult(image: image)
            }
        }
        if Task.isCancelled { return PreviewResult() }
        return await generateLane.run(key: key, priority: priority) { [self] in
            generateAndStore(photo, level: level, settings: s, memoryKey: key)
        } ?? PreviewResult()
    }

    /// Low-priority warm-up (e.g. rows just below the visible area). Fire and forget.
    func prefetch(_ photos: [Photo], level: PreviewLevel = .thumbnail) {
        for photo in photos where cachedImage(for: photo, level: level) == nil {
            Task.detached(priority: .utility) { _ = await self.load(photo, level: level, priority: .background) }
        }
    }

    /// Makes sure a disk preview exists (build jobs). Doesn't fill the memory cache.
    /// Returns false if it could not be generated (offline / unreadable).
    @concurrent
    func ensureOnDisk(_ photo: Photo, level: PreviewLevel) async -> Bool {
        guard let disk, photo.id != 0 else { return false }
        let s = settings
        if disk.exists(photoID: photo.id, name: diskName(photo, level, s)) { return true }
        let key = memoryKey(photo, level)
        let result = await generateLane.run(key: key, priority: .background) { [self] in
            generateAndStore(photo, level: level, settings: s, memoryKey: nil)
        }
        return result?.image != nil && result?.isOffline == false
    }

    /// Queues a background job that builds previews for `photoIDs` (existing ones are skipped).
    /// Callable from any thread; progress/cancel via `PreviewJobs.shared`.
    /// Importers: call after inserting, e.g. `PreviewService.shared.build(photoIDs: ids, levels: [.thumbnail])`.
    func build(photoIDs: [Int64], levels: [PreviewLevel] = [.thumbnail, .standard], title: String? = nil) {
        guard !photoIDs.isEmpty else { return }
        Task { @MainActor in
            PreviewJobs.shared.enqueue(title: title ?? "Building previews", photoIDs: photoIDs, levels: levels)
        }
    }

    // MARK: - Invalidation / cleaning

    /// Forces regeneration of a photo's previews (deletes its disk previews too).
    /// Not needed after edits: `edit_version` is part of the cache key.
    func invalidate(photoID: Int64) {
        discard(photoIDs: [photoID])
    }

    /// Deletes the previews (memory + disk) of these photos; views reload them.
    func discard(photoIDs: some Collection<Int64>) {
        lock.lock()
        for id in photoIDs { generations[id, default: 0] += 1 }
        lock.unlock()
        disk?.remove(photoIDs: photoIDs)
        PreviewJobs.notifyChanged(Set(photoIDs))
    }

    /// Deletes every cached preview ("Clean Cache").
    func discardAll() {
        lock.lock(); epoch += 1; lock.unlock()
        cache.removeAllObjects()
        disk?.removeAll()
        PreviewJobs.notifyAllChanged()
    }

    /// Drops decoded images from memory only (disk cache untouched).
    func purgeMemoryCache() {
        cache.removeAllObjects()
    }

    /// Bytes used by the disk cache (scans; call off the main thread).
    @concurrent
    func diskUsage() async -> Int64 {
        disk?.computeUsage() ?? 0
    }

    /// Prunes least recently used previews if the cache exceeds the configured limit.
    func pruneIfNeeded() {
        guard let disk, let max = settings.maxCacheBytes else { return }
        if (disk.approximateUsage ?? disk.computeUsage()) > max { disk.prune(maxBytes: max) }
    }

    // MARK: - Keys

    private func memoryKey(_ photo: Photo, _ level: PreviewLevel) -> String {
        let id = photo.id != 0 ? String(photo.id) : photo.path
        lock.lock()
        let gen = generations[photo.id] ?? 0
        let epoch = epoch
        let sig = _settings.signature(for: level, edited: Self.isEdited(photo))
        lock.unlock()
        return "\(id)-\(photo.editVersion)-\(gen).\(epoch)-\(level.rawValue)-\(sig)"
    }

    private func diskName(_ photo: Photo, _ level: PreviewLevel, _ s: PreviewSettings) -> String {
        PreviewDiskCache.fileName(photoID: photo.id, level: level, editVersion: photo.editVersion,
                                  signature: s.signature(for: level, edited: Self.isEdited(photo)))
    }

    /// Cheap "has edits" for keys (`Photo.hasEdits` decodes JSON; default settings are stored as NULL).
    private static func isEdited(_ photo: Photo) -> Bool { photo.editSettingsJSON != nil }

    private static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    // MARK: - Generation (runs on generateLane workers)

    private func generateAndStore(_ photo: Photo, level: PreviewLevel, settings s: PreviewSettings, memoryKey: String?) -> PreviewResult {
        let disk = photo.id != 0 ? disk : nil
        let name = diskName(photo, level, s)
        // Another request (or a build job) may have written it meanwhile.
        if let disk, let image = disk.read(photoID: photo.id, name: name) {
            if let memoryKey { cache.setObject(image, forKey: memoryKey as NSString, cost: Self.cost(image)) }
            return PreviewResult(image: image)
        }

        let image = generate(photo, level: level, settings: s, disk: disk)
        guard let image else {
            let offline = !isReadable(photo)
            if offline, photo.id != 0 { lock.lock(); offlineIDs.insert(photo.id); lock.unlock() }
            return PreviewResult(image: disk?.readAnyVersion(photoID: photo.id, level: level), isOffline: offline)
        }
        if let memoryKey { cache.setObject(image, forKey: memoryKey as NSString, cost: Self.cost(image)) }
        if let disk {
            disk.write(image, photoID: photo.id, level: level, name: name, quality: s.quality)
            noteWrite()
        }
        return PreviewResult(image: image)
    }

    private func generate(_ photo: Photo, level: PreviewLevel, settings s: PreviewSettings, disk: PreviewDiskCache?) -> CGImage? {
        let size = s.pixelSize(for: level)
        let edited = photo.hasEdits

        // A thumbnail of an edited photo is much cheaper to downsample from its standard preview.
        if edited, level == .thumbnail, let disk {
            let standard = diskName(photo, .standard, s)
            if let image = disk.read(photoID: photo.id, name: standard, maxPixelSize: size) { return image }
        }

        let url: URL
        if let catalog { url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog) } else { url = photo.url }

        if !edited && s.useEmbeddedPreviews {
            let wanted = min(size, max(photo.width, photo.height) > 0 ? max(photo.width, photo.height) : size)
            if let embedded = Self.embeddedPreview(url: url, maxPixelSize: size),
               max(embedded.width, embedded.height) * 10 >= wanted * 9 {
                return embedded
            }
            // No (large enough) embedded preview: decode + downsample the image itself. RAWs are
            // rendered below so they match Develop.
            if !RenderPipeline.isRAW(url: url) { return PreviewDiskCache.decode(url: url, maxPixelSize: size) }
        }
        renderSlots.wait()
        defer { renderSlots.signal() }
        return RenderPipeline.renderCGImage(url: url, settings: photo.editSettings, maxPixelSize: size)
    }

    private func isReadable(_ photo: Photo) -> Bool {
        let url = catalog.map { SecurityScopeManager.shared.accessibleURL(for: photo, catalog: $0) } ?? photo.url
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private func noteWrite() {
        lock.lock()
        writesSinceCheck += 1
        let check = writesSinceCheck >= 50
        if check { writesSinceCheck = 0 }
        lock.unlock()
        if check { maintenanceQueue.async { [weak self] in self?.pruneIfNeeded() } }
    }

    // MARK: - Root access changes

    /// A root was added / granted / removed: forget cached scope failures and make views that
    /// showed "offline" retry (their `ThumbnailView` revision is bumped). No app restart needed.
    private func rootsChanged() {
        SecurityScopeManager.shared.forgetFailures()
        lock.lock()
        let ids = offlineIDs
        offlineIDs.removeAll()
        lock.unlock()
        if !ids.isEmpty { PreviewJobs.notifyChanged(ids) }
    }

    // MARK: - Eager regeneration after edits

    /// `.photosUpdated` also fires for flags/ratings; after 1 s of quiet, regenerate thumbnails
    /// that exist on disk only in an older version (i.e. the photo's edits changed).
    private func photosUpdated(_ ids: Set<Int64>) {
        lock.lock()
        pendingEdited.formUnion(ids)
        editDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.regenerateStaleThumbnails() }
        editDebounce = work
        lock.unlock()
        maintenanceQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func regenerateStaleThumbnails() {
        lock.lock()
        let ids = Array(pendingEdited)
        pendingEdited.removeAll()
        lock.unlock()
        guard let catalog, let disk, let photos = try? catalog.photos(ids: ids) else { return }
        let s = settings
        for photo in photos {
            let name = diskName(photo, .thumbnail, s)
            guard !disk.exists(photoID: photo.id, name: name), disk.hasAnyVersion(photoID: photo.id, level: .thumbnail) else { continue }
            Task.detached(priority: .utility) { _ = await self.load(photo, level: .thumbnail, priority: .background) }
        }
    }

    // MARK: - ImageIO

    /// The embedded preview only (never decodes the RAW); nil if the file has none.
    static func embeddedPreview(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Fast ImageIO thumbnail (embedded JPEG for RAW when present), orientation applied.
    static func embeddedThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
