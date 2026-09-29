//
//  RecentRendersPrefetch.swift
//  sloproom
//
//  Develop neighbour warm-up, so arrowing through photos is instant. When a photo opens in
//  Develop (`AppModel` calls `developOpened(index:in:)`):
//  - the next / previous photos (and the one after next, in the direction of travel) get their
//    recent render loaded into memory, or else their standard preview (sharper placeholder than
//    the thumbnail);
//  - the RAW file of the next photo is read ahead at background priority into the OS file cache
//    (one file at a time; a newer request cancels an older one), so its decode doesn't wait for
//    the external drive.
//  Memory stays bounded by the caches' own limits (RecentRenders LRU, PreviewService NSCache).
//

import Foundation

nonisolated final class RecentRendersPrefetch: @unchecked Sendable {
    static let shared = RecentRendersPrefetch()

    private let lock = NSLock()
    private var lastIndex: Int?
    private var direction = 1
    /// Bumped per request; an older read-ahead stops when it sees a newer generation.
    private var generation = 0
    private var readAheadPath: String?
    private let readQueue = DispatchQueue(label: "Sloproom.RecentRenders.readAhead", qos: .background)

    /// Also a switch for measuring (DEBUG: `-previews.developPrefetch NO`).
    var isEnabled = UserDefaults.standard.object(forKey: "previews.developPrefetch") == nil
        || UserDefaults.standard.bool(forKey: "previews.developPrefetch")

    // Statistics
    private(set) var readAheadFiles = 0
    private(set) var readAheadBytes: Int64 = 0

    /// `photos` = the Develop photo list (filmstrip order); `index` = the photo just opened.
    func developOpened(index: Int, in photos: [Photo]) {
        guard isEnabled, photos.indices.contains(index) else { return }
        lock.lock()
        // Direction of travel from arrowing (±1); a jump (filmstrip click) keeps it / defaults to forward.
        if let last = lastIndex, abs(index - last) == 1 { direction = index > last ? 1 : -1 }
        lastIndex = index
        let dir = direction
        generation += 1
        let gen = generation
        lock.unlock()

        let order = [index + dir, index - dir, index + 2 * dir].filter { photos.indices.contains($0) }
        let neighbours = order.map { photos[$0] }
        DispatchQueue.global(qos: .utility).async {
            for photo in neighbours {
                let hash = RecentRenderKey.settingsHash(photo.editSettings)
                if !RecentRenders.shared.prefetch(photoID: photo.id, settingsHash: hash),
                   PreviewService.shared.cachedImage(for: photo, level: .standard) == nil {
                    PreviewService.shared.prefetch([photo], level: .standard)
                }
            }
        }
        if let next = neighbours.first { readAhead(next, generation: gen) }
    }

    /// Reads the file sequentially (1 MB chunks, background QoS) so it lands in the OS file cache.
    private func readAhead(_ photo: Photo, generation gen: Int) {
        guard let catalog = PreviewService.shared.catalog else { return }
        // Give the photo being opened a head start on the drive.
        readQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
            self.lock.lock()
            let current = self.generation == gen && self.readAheadPath != url.path
            if current { self.readAheadPath = url.path }
            self.lock.unlock()
            guard current else { return }
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let chunk = 1 << 20
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            var total: Int64 = 0
            while true {
                self.lock.lock()
                let stale = self.generation != gen
                if stale { self.readAheadPath = nil } // interrupted: may be read again later
                self.lock.unlock()
                if stale { break }
                let n = read(fd, buffer, chunk)
                if n <= 0 { break }
                total += Int64(n)
            }
            self.lock.lock()
            self.readAheadFiles += 1
            self.readAheadBytes += total
            self.lock.unlock()
        }
    }

    /// Forgets navigation state and stops a read-ahead in progress (catalog replaced).
    func reset() {
        lock.lock()
        lastIndex = nil
        direction = 1
        generation += 1
        readAheadPath = nil
        lock.unlock()
    }

    var statsDescription: String {
        lock.lock(); defer { lock.unlock() }
        return "readAhead files=\(readAheadFiles) MB=\(readAheadBytes / 1_000_000) enabled=\(isEnabled)"
    }
}
