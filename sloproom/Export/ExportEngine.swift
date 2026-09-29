//
//  ExportEngine.swift
//  sloproom
//
//  JPEG export (UI-free; compiled by Tools/export_check.swift). For each photo: full-resolution
//  render through RenderPipeline with its saved EditSettings (crop, rotation, masks, effects),
//  8-bit sRGB, ImageIO JPEG at `quality`, source metadata kept (capture date + offset, camera,
//  lens, exposure, GPS) with Orientation = 1 and the output's pixel size. Files are written as
//  a hidden temp file in the destination and renamed into place without ever overwriting
//  ("L1090228.jpg", then "L1090228-1.jpg", …).
//
//  Usage (off the main thread):
//      let job = ExportJob(catalog: catalog, photoIDs: ids, options: ExportOptions(destination: url, quality: 85))
//      let result = job.run { progress in … }      // blocks; job.cancel() from anywhere
//
//  The destination must be writable: `ExportFiles.checkWriteAccess(_:)` (a probe file) fails with
//  `ExportError.noWriteAccess` while the app only has the read-only user-selected-files entitlement.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ExportOptions: Sendable {
    /// Existing, writable directory (caller holds its security scope).
    var destination: URL
    /// JPEG quality 0...100 (→ kCGImageDestinationLossyCompressionQuality = quality / 100).
    var quality: Int = 85
    /// Renders in flight at once (full-resolution RAW renders are memory-heavy).
    var maxConcurrentRenders = 2
}

nonisolated struct ExportProgress: Sendable {
    var total = 0
    /// Photos finished (exported or skipped).
    var done = 0
    var exported = 0
    var skipped = 0
}

nonisolated enum ExportSkipReason: Sendable, Hashable, CustomStringConvertible {
    /// The original isn't there (drive not connected, no access, moved).
    case offline
    /// The file exists but can't be decoded / rendered.
    case unreadable
    /// Rendering or writing failed.
    case failed(String)

    var description: String {
        switch self {
        case .offline: "offline"
        case .unreadable: "unreadable"
        case .failed(let why): why
        }
    }
    /// Short label for summaries ("1 skipped (offline)").
    var label: String {
        switch self {
        case .offline: "offline"
        case .unreadable: "unreadable"
        case .failed: "failed"
        }
    }
}

nonisolated struct ExportedFile: Sendable {
    var photoID: Int64
    var url: URL
    var pixelWidth: Int
    var pixelHeight: Int
    /// Full-resolution render (decode + all stages) and JPEG encode + write, seconds.
    var renderSeconds: Double
    var encodeSeconds: Double
    var bytes: Int
}

nonisolated struct ExportSkip: Sendable {
    var photoID: Int64
    var fileName: String
    var reason: ExportSkipReason
}

nonisolated struct ExportResult: Sendable {
    var exported: [ExportedFile] = []
    var skipped: [ExportSkip] = []
    var wasCancelled = false
    /// The export stopped early (e.g. the destination became unwritable).
    var stopError: ExportError?
    var elapsed: TimeInterval = 0

    /// "12 exported, 1 skipped (offline)".
    var summary: String {
        var parts = ["\(exported.count) exported"]
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in skipped {
            if counts[s.reason.label] == nil { order.append(s.reason.label) }
            counts[s.reason.label, default: 0] += 1
        }
        for label in order { parts.append("\(counts[label]!) skipped (\(label))") }
        return parts.joined(separator: ", ") + (wasCancelled ? " — cancelled" : "")
    }
}

nonisolated enum ExportError: LocalizedError, CustomStringConvertible, Sendable {
    case noWriteAccess(String)
    case unavailable(String)
    case io(String, Int32)

    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .noWriteAccess(let path):
            "Sloproom doesn't have write access to “\(path)”. Enable User Selected File: Read/Write in Signing & Capabilities."
        case .unavailable(let path):
            "“\(path)” is not available. Connect the drive or choose another folder."
        case .io(let what, let code): "\(what): \(String(cString: strerror(code)))"
        }
    }

    static func isPermission(_ code: Int32) -> Bool { [EACCES, EPERM, EROFS].contains(code) }
}

// MARK: - Files

nonisolated enum ExportFiles {
    static let tempPrefix = ".sloproom-export-"

    /// Throws `ExportError.unavailable` / `.noWriteAccess` unless a file can be created in `directory`.
    static func checkWriteAccess(_ directory: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            // Unreadable (no grant) looks like missing; tell those apart by the parent's listing.
            let parent = directory.deletingLastPathComponent().path
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: parent))?.contains(directory.lastPathComponent)
            throw listed == false ? ExportError.unavailable(directory.path) : ExportError.noWriteAccess(directory.path)
        }
        let probe = directory.appendingPathComponent(".sloproom-write-check-\(UUID().uuidString)").path
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            let code = errno
            throw ExportError.isPermission(code) ? ExportError.noWriteAccess(directory.path)
                : ExportError.io("Can't write to \(directory.path)", code)
        }
        close(fd)
        unlink(probe)
    }

    /// "L1090228.jpg", "L1090228-1.jpg", … — the first name that neither exists in `directory`
    /// nor is in `reserved` (names claimed by other photos of the same export, case-insensitive).
    static func uniqueFileName(base: String, ext: String = "jpg", in directory: URL, reserved: Set<String>) -> String {
        let fm = FileManager.default
        for n in 0... {
            let name = (n == 0 ? base : "\(base)-\(n)") + "." + ext
            if reserved.contains(name.lowercased()) { continue }
            if fm.fileExists(atPath: directory.appendingPathComponent(name).path) { continue }
            return name
        }
        return base + "." + ext
    }

    /// Writes `data` to a hidden temp file in `directory` (exclusive create + fsync), then renames it
    /// to `name` without overwriting. If `name` got taken meanwhile, `nextName` supplies another.
    /// Returns the final URL; on failure the temp file is removed.
    static func write(_ data: Data, named name: String, in directory: URL, nextName: (String) -> String) throws -> URL {
        let tmp = directory.appendingPathComponent(tempPrefix + UUID().uuidString + ".jpg.tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            let code = errno
            throw ExportError.isPermission(code) ? ExportError.noWriteAccess(directory.path)
                : ExportError.io("Can't create a file in \(directory.path)", code)
        }
        var ok = false
        defer { if !ok { unlink(tmp) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var written = 0
                while written < buf.count {
                    let w = Darwin.write(fd, buf.baseAddress! + written, buf.count - written)
                    if w < 0 {
                        let code = errno
                        throw ExportError.isPermission(code) ? ExportError.noWriteAccess(directory.path)
                            : ExportError.io("Write error in \(name)", code)
                    }
                    written += w
                }
            }
            if fsync(fd) != 0 { throw ExportError.io("Can't flush \(name)", errno) }
        }
        var target = name
        for _ in 0..<1000 {
            let dest = directory.appendingPathComponent(target)
            if renamex_np(tmp, dest.path, UInt32(RENAME_EXCL)) == 0 {
                ok = true
                return dest
            }
            let code = errno
            guard code == EEXIST else { throw ExportError.io("Can't rename to \(target)", code) }
            target = nextName(target)
        }
        throw ExportError.io("Can't rename to \(name)", EEXIST)
    }

    /// Leftover temp files of an interrupted export (should be none).
    static func tempFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(tempPrefix) }
    }
}

// MARK: - Metadata

nonisolated enum ExportMetadata {
    /// ImageIO properties for the exported JPEG: EXIF (dates + offsets, exposure, lens), ExifAux,
    /// camera make/model, GPS and IPTC from `url`; Orientation 1, the output pixel size, sRGB.
    /// RAW files without OffsetTime* take them from the RAW+JPEG `sidecar` when its capture
    /// wall-clock time matches (Leica writes the offset only into the JPEG).
    static func properties(source url: URL, sidecar: URL?, pixelWidth: Int, pixelHeight: Int,
                           quality: Int) -> [CFString: Any] {
        let src = read(url)
        var out: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 0), 100)) / 100,
            kCGImagePropertyOrientation: 1,
        ]

        var exif = src[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for key in droppedExifKeys { exif.removeValue(forKey: key) }
        if exif[kCGImagePropertyExifOffsetTimeOriginal] == nil, let sidecar,
           let sideExif = read(sidecar)[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let a = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let b = sideExif[kCGImagePropertyExifDateTimeOriginal] as? String, a.prefix(16) == b.prefix(16) {
            for key in [kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized] {
                if let v = sideExif[key] { exif[key] = v }
            }
        }
        exif[kCGImagePropertyExifPixelXDimension] = pixelWidth
        exif[kCGImagePropertyExifPixelYDimension] = pixelHeight
        exif[kCGImagePropertyExifColorSpace] = 1 // sRGB
        out[kCGImagePropertyExifDictionary] = exif

        let tiffIn = src[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1, kCGImagePropertyTIFFSoftware: "Sloproom"]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                    kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription] {
            if let v = tiffIn[key] { tiff[key] = v }
        }
        out[kCGImagePropertyTIFFDictionary] = tiff

        for key in [kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let d = src[key] as? [CFString: Any], !d.isEmpty { out[key] = d }
        }
        return out
    }

    /// Sensor / RAW-layout fields that don't describe the exported image.
    private static let droppedExifKeys: [CFString] = [
        kCGImagePropertyExifCFAPattern, kCGImagePropertyExifSubjectArea, kCGImagePropertyExifSubjectLocation,
        kCGImagePropertyExifMakerNote, kCGImagePropertyExifGamma,
    ]

    private static func read(_ url: URL) -> [CFString: Any] {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts), CGImageSourceGetCount(src) > 0 else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), opts) as? [CFString: Any] ?? [:]
    }
}

// MARK: - Job

/// One export run. `run` is synchronous — call it off the main thread; `cancel()` from anywhere
/// (photos already written stay; a photo being rendered is dropped, never half-written).
nonisolated final class ExportJob: @unchecked Sendable {
    let catalog: Catalog
    let photoIDs: [Int64]
    let options: ExportOptions
    /// Settings to use instead of the catalog's (e.g. the Develop session's unsaved edits).
    let settingsOverride: [Int64: EditSettings]

    private let lock = NSLock()
    private var cancelled = false
    /// Lower-cased file names claimed by this job (so concurrent renders never pick the same name).
    private var reserved: Set<String> = []

    init(catalog: Catalog, photoIDs: [Int64], options: ExportOptions, settingsOverride: [Int64: EditSettings] = [:]) {
        self.catalog = catalog
        self.photoIDs = photoIDs
        self.options = options
        self.settingsOverride = settingsOverride
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Exports every photo (up to `maxConcurrentRenders` at once). `progress` is called from worker
    /// threads after each photo.
    func run(progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) -> ExportResult {
        let start = Date()
        var result = ExportResult()
        let photos: [Photo]
        do {
            let byID = Dictionary(try catalog.photos(ids: photoIDs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            photos = photoIDs.compactMap { byID[$0] }
        } catch {
            result.stopError = .io("Can't read the catalog (\(error))", EIO)
            return result
        }
        let destination = options.destination
        do { try ExportFiles.checkWriteAccess(destination) } catch {
            result.stopError = error as? ExportError ?? .io("\(error)", EIO)
            result.elapsed = Date().timeIntervalSince(start)
            return result
        }

        let state = RunState(total: photos.count)
        let group = DispatchGroup()
        let workers = max(1, min(options.maxConcurrentRenders, photos.count))
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while !self.isCancelled, let i = state.take(), i < photos.count {
                    let photo = photos[i]
                    let outcome = autoreleasepool { self.export(photo) }
                    if let snapshot = state.record(outcome, index: i, photo: photo) { progress(snapshot) }
                }
            }
        }
        group.wait()

        state.fill(&result)
        result.wasCancelled = isCancelled
        result.elapsed = Date().timeIntervalSince(start)
        return result
    }

    /// Shared bookkeeping of the workers (lock-protected).
    private nonisolated final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var stats: ExportProgress
        private var exported: [Int: ExportedFile] = [:]
        private var skipped: [Int: ExportSkip] = [:]
        private var stopError: ExportError?

        init(total: Int) { stats = ExportProgress(total: total) }

        /// Next photo index, or nil once the export was stopped.
        func take() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard stopError == nil else { return nil }
            next += 1
            return next - 1
        }

        /// Returns the progress to report (nil when nothing finished).
        func record(_ outcome: Outcome, index i: Int, photo: Photo) -> ExportProgress? {
            lock.lock(); defer { lock.unlock() }
            switch outcome {
            case .exported(let file):
                exported[i] = file
                stats.exported += 1
            case .skipped(let reason):
                skipped[i] = ExportSkip(photoID: photo.id, fileName: photo.fileName, reason: reason)
                stats.skipped += 1
            case .stop(let error):
                if stopError == nil { stopError = error }
                return nil
            case .cancelled:
                return nil
            }
            stats.done += 1
            return stats
        }

        func fill(_ result: inout ExportResult) {
            lock.lock(); defer { lock.unlock() }
            result.exported = exported.keys.sorted().map { exported[$0]! }
            result.skipped = skipped.keys.sorted().map { skipped[$0]! }
            result.stopError = stopError
        }
    }

    fileprivate nonisolated enum Outcome {
        case exported(ExportedFile)
        case skipped(ExportSkipReason)
        /// Stops the whole export (the destination became unwritable).
        case stop(ExportError)
        /// Cancelled while rendering: nothing written.
        case cancelled
    }

    /// Renders and writes one photo.
    private func export(_ photo: Photo) -> Outcome {
        let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .skipped(.offline) }
        let sidecar = photo.sidecarURL.map { u in
            SecurityScope.withAccess(to: u, catalog: catalog) { $0 }
        }
        let settings = settingsOverride[photo.id] ?? photo.editSettings

        let t0 = Date()
        guard let source = RenderPipeline.makeSource(url: url) else { return .skipped(.unreadable) }
        guard let image = RenderPipeline.renderCGImage(source: source, settings: settings, colorSpace: RenderPipeline.sRGB) else {
            return .skipped(.failed("render failed"))
        }
        let renderSeconds = Date().timeIntervalSince(t0)
        if isCancelled { return .cancelled }

        let t1 = Date()
        let props = ExportMetadata.properties(source: url, sidecar: sidecar, pixelWidth: image.width,
                                              pixelHeight: image.height, quality: options.quality)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return .skipped(.failed("JPEG encoder unavailable"))
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return .skipped(.failed("JPEG encoding failed")) }

        let base = (photo.fileName as NSString).deletingPathExtension
        let written: URL
        do {
            written = try ExportFiles.write(data as Data, named: reserveName(base: base), in: options.destination) { _ in
                self.reserveName(base: base)
            }
        } catch let error as ExportError {
            if case .noWriteAccess = error { return .stop(error) }
            return .skipped(.failed(error.description))
        } catch {
            return .skipped(.failed("\(error)"))
        }
        return .exported(ExportedFile(photoID: photo.id, url: written, pixelWidth: image.width, pixelHeight: image.height,
                                      renderSeconds: renderSeconds, encodeSeconds: Date().timeIntervalSince(t1),
                                      bytes: data.length))
    }

    private func reserveName(base: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let name = ExportFiles.uniqueFileName(base: base, in: options.destination, reserved: reserved)
        reserved.insert(name.lowercased())
        return name
    }
}
