//
//  ImportEngine.swift
//  sloproom
//
//  UI-free SD card / folder import engine (also used by Tools/sdimport_check.swift):
//    1. `ImportScanner.enumerate` lists supported photos under a source (recursive, no hidden files).
//    2. `ImportScanner.candidates` pairs RAW + JPEG with the same base name (JPEG = sidecar).
//    3. `ImportScanner.readMetadata` reads EXIF (header only, parallel) for the grid / duplicates.
//    4. `DuplicateIndex` flags files already in the catalog (same path, or name + size + capture date).
//    5. `ImportJob.run` copies safely (`name.tmp` → verify size → exclusive rename, never overwrite),
//       inserts photos in batches with ONE import date, adds them to a folder, reports progress.
//
//  The caller must already have sandbox access to the source and destination.
//

import Foundation
import CoreGraphics

// MARK: - Model

/// A photo file found in the source.
nonisolated struct ImportFile: Sendable, Hashable, Identifiable {
    var url: URL
    var fileSize: Int64
    var modificationDate: Date?
    var isRAW: Bool

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
}

/// One importable photo: the primary file plus an optional sidecar (JPEG next to a RAW).
nonisolated struct ImportCandidate: Sendable, Hashable, Identifiable {
    var primary: ImportFile
    var sidecar: ImportFile?

    var id: String { primary.id }
    var files: [ImportFile] { sidecar.map { [primary, $0] } ?? [primary] }
    var totalSize: Int64 { primary.fileSize + (sidecar?.fileSize ?? 0) }
}

nonisolated enum ImportMode: String, Sendable, CaseIterable, Identifiable {
    /// Copy files to the destination, then add the copies.
    case copy
    /// Add the files where they are (no copy).
    case addInPlace
    var id: String { rawValue }
    var title: String { self == .copy ? "Copy to Destination" : "Add in Place" }
}

/// Destination subfolder layout by capture date.
nonisolated enum DestinationPattern: String, Sendable, CaseIterable, Identifiable {
    case yearAndDay   // 2026/2026-08-01
    case day          // 2026-08-01
    case none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yearAndDay: "YYYY/YYYY-MM-DD"
        case .day: "YYYY-MM-DD"
        case .none: "None (flat)"
        }
    }

    /// Relative subfolder for `date` in the local calendar ("" for `.none`).
    func subpath(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", c.year ?? 0)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        switch self {
        case .yearAndDay: return y + "/" + day
        case .day: return day
        case .none: return ""
        }
    }
}

nonisolated struct ImportOptions: Sendable {
    var mode: ImportMode = .copy
    /// Destination root directory (copy mode). Must be writable (read/write security scope).
    var destination: URL?
    var pattern: DestinationPattern = .yearAndDay
    /// Existing catalog folder to add the photos to (or the parent of `newFolderName`).
    var targetFolderID: Int64?
    /// Create a folder with this name (inside `targetFolderID` if set) and add the photos to it.
    var newFolderName: String?
}

nonisolated struct ImportProgress: Sendable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var photosAdded = 0
    var currentFile: String?
    var elapsed: TimeInterval = 0

    var fraction: Double {
        bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal)
            : filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
    }
    /// Bytes per second (nil until there's enough data).
    var rate: Double? { elapsed > 0.5 && bytesDone > 0 ? Double(bytesDone) / elapsed : nil }
    var eta: TimeInterval? { rate.map { Double(bytesTotal - bytesDone) / $0 } }
}

nonisolated struct ImportResult: Sendable {
    var importDate: Date
    var photoIDs: [Int64] = []
    /// Folder the photos were added to (new or existing), if any.
    var folderID: Int64?
    var filesCopied = 0
    var bytesCopied: Int64 = 0
    var wasCancelled = false
    /// Per-file problems that didn't stop the import.
    var failures: [String] = []
    /// Set when the import stopped early (e.g. no write access). Photos copied before that are
    /// still catalogued.
    var stopError: ImportError?
    var elapsed: TimeInterval = 0
}

nonisolated enum ImportError: LocalizedError, CustomStringConvertible {
    case noWriteAccess(String)
    case noDestination
    case sizeMismatch(String)
    case io(String, Int32)

    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .noWriteAccess(let path):
            "Sloproom doesn't have write access to “\(path)”; enable User Selected File: Read/Write (or pick a folder you can write to)."
        case .noDestination: "Choose a destination folder first."
        case .sizeMismatch(let name): "Copy of \(name) is incomplete (size mismatch)."
        case .io(let what, let code): "\(what): \(String(cString: strerror(code)))"
        }
    }

    static func isPermission(_ error: Error) -> Bool {
        if case ImportError.noWriteAccess = error { return true }
        if case ImportError.io(_, let code) = error { return [EACCES, EPERM, EROFS].contains(code) }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, [EACCES, EPERM, EROFS].contains(Int32(ns.code)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermission(underlying) }
        return false
    }
}

// MARK: - Scanning

nonisolated enum ImportScanner {
    /// Recursively lists supported photos under `directory` (hidden files and packages skipped;
    /// videos and other files ignored), sorted by path. `progress` gets the running count.
    static func enumerate(_ directory: URL, isCancelled: () -> Bool = { false },
                          progress: (Int) -> Void = { _ in }) -> [ImportFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [ImportFile] = []
        for case let url as URL in e {
            if isCancelled() { break }
            guard PhotoMetadataReader.isSupportedImage(url: url),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append(ImportFile(url: url, fileSize: Int64(v.fileSize ?? 0), modificationDate: v.contentModificationDate,
                                    isRAW: PhotoMetadataReader.isRAW(url: url)))
            if files.count % 100 == 0 { progress(files.count) }
        }
        progress(files.count)
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// Candidates in input order. With `pairSidecars`, a JPEG (or other non-RAW) with the same
    /// directory + base name (case-insensitive) as a RAW becomes that RAW's sidecar.
    static func candidates(from files: [ImportFile], pairSidecars: Bool) -> [ImportCandidate] {
        guard pairSidecars else { return files.map { ImportCandidate(primary: $0) } }
        func key(_ f: ImportFile) -> String { f.url.deletingPathExtension().path.lowercased() }
        let rawKeys = Set(files.filter(\.isRAW).map(key))
        var sidecars: [String: ImportFile] = [:]
        for f in files where !f.isRAW && rawKeys.contains(key(f)) {
            // Prefer JPEG over HEIC/TIFF if several.
            let isJPEG = ["jpg", "jpeg"].contains(f.url.pathExtension.lowercased())
            if sidecars[key(f)] == nil || isJPEG { sidecars[key(f)] = f }
        }
        let sidecarIDs = Set(sidecars.values.map(\.id))
        return files.compactMap { f in
            if sidecarIDs.contains(f.id) { return nil }
            return ImportCandidate(primary: f, sidecar: f.isRAW ? sidecars[key(f)] : nil)
        }
    }

    /// Reads metadata of `files` in parallel. Unreadable files are absent from the result.
    static func readMetadata(_ files: [ImportFile]) -> [String: PhotoMetadata] {
        var results = [PhotoMetadata?](repeating: nil, count: files.count)
        results.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let base = buf.baseAddress! // each iteration writes its own slot
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                base[i] = PhotoMetadataReader.read(url: files[i].url)
            }
        }
        var out: [String: PhotoMetadata] = [:]
        for (f, m) in zip(files, results) { if let m { out[f.id] = m } }
        PhotoMetadataReader.adoptSidecarOffsets(&out)   // RAW without zone offset: use its JPEG's
        return out
    }

    /// Date used for grouping / destination folders.
    static func date(of file: ImportFile, metadata: PhotoMetadata?) -> Date? {
        metadata?.captureDate ?? file.modificationDate
    }
}

/// Snapshot of the catalog for "already imported" detection. Build once per scan (off-main).
nonisolated struct DuplicateIndex: Sendable {
    private var paths: Set<String> = []
    /// "lowercased file name|size" -> capture dates of catalog photos.
    private var fingerprints: [String: [Date?]] = [:]

    init(catalog: Catalog) throws {
        for f in try catalog.importFingerprints() {
            paths.insert(f.path)
            fingerprints["\(f.fileName.lowercased())|\(f.fileSize)", default: []].append(f.captureDate)
        }
    }

    init() {}

    /// True if a photo with the same path is catalogued, or one with the same file name + size
    /// and (when both are known) a capture date within a second.
    func isDuplicate(_ file: ImportFile, metadata: PhotoMetadata?) -> Bool {
        if paths.contains(file.url.standardizedFileURL.path) { return true }
        guard let dates = fingerprints["\(file.fileName.lowercased())|\(file.fileSize)"] else { return false }
        guard let date = metadata?.captureDate else { return true }
        return dates.contains { d in d.map { abs($0.timeIntervalSince(date)) < 1 } ?? true }
    }

    /// Remember files imported in this session (so re-scans before a catalog reload still match).
    mutating func add(_ file: ImportFile, metadata: PhotoMetadata?) {
        paths.insert(file.url.standardizedFileURL.path)
        fingerprints["\(file.fileName.lowercased())|\(file.fileSize)", default: []].append(metadata?.captureDate)
    }
}

// MARK: - File operations

nonisolated enum ImportFiles {
    /// Throws `ImportError.noWriteAccess` if files can't be created in `directory` (creates it).
    static func checkWriteAccess(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ImportError.isPermission(error) ? ImportError.noWriteAccess(directory.path) : error
        }
        let probe = directory.appendingPathComponent(".sloproom-write-check-\(UUID().uuidString)").path
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            let code = errno
            throw [EACCES, EPERM, EROFS].contains(code) ? ImportError.noWriteAccess(directory.path)
                : ImportError.io("Can't write to \(directory.path)", code)
        }
        close(fd)
        unlink(probe)
    }

    /// Picks a base name so that `base.<ext>` for every extension (and its `.tmp`) is free in
    /// `directory`: "L1000123", then "L1000123-1", "-2", … Keeps RAW + JPEG pairs matching.
    static func uniqueBaseName(_ base: String, extensions: [String], in directory: URL) -> String {
        let fm = FileManager.default
        for n in 0... {
            let candidate = n == 0 ? base : "\(base)-\(n)"
            let taken = extensions.contains { ext in
                let name = ext.isEmpty ? candidate : candidate + "." + ext
                let path = directory.appendingPathComponent(name).path
                return fm.fileExists(atPath: path) || fm.fileExists(atPath: path + ".tmp")
            }
            if !taken { return candidate }
        }
        return base
    }

    /// Copies `source` to `destination` via `destination.tmp` (exclusive create), fsyncs,
    /// verifies the size, preserves dates, then renames without ever overwriting. On any failure
    /// or cancellation the temp file is removed. `onBytes` gets each chunk's byte count.
    static func copy(_ source: URL, to destination: URL, isCancelled: () -> Bool = { false },
                     onBytes: (Int64) -> Void = { _ in }) throws -> Int64 {
        let tmp = destination.path + ".tmp"
        let src = open(source.path, O_RDONLY)
        guard src >= 0 else { throw ImportError.io("Can't read \(source.lastPathComponent)", errno) }
        defer { close(src) }
        _ = fcntl(src, F_NOCACHE, 1) // big sequential read: don't pollute the page cache

        let dst = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard dst >= 0 else {
            let code = errno
            if [EACCES, EPERM, EROFS].contains(code) { throw ImportError.noWriteAccess(destination.deletingLastPathComponent().path) }
            throw ImportError.io("Can't create \(tmp)", code)
        }
        var ok = false
        defer { if !ok { unlink(tmp) } }

        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        do {
            defer { close(dst) }
            while true {
                if isCancelled() { throw CancellationError() }
                let n = read(src, buffer, chunk)
                if n < 0 { throw ImportError.io("Read error in \(source.lastPathComponent)", errno) }
                if n == 0 { break }
                var written = 0
                while written < n {
                    let w = write(dst, buffer + written, n - written)
                    if w < 0 {
                        let code = errno
                        if [EACCES, EPERM, EROFS].contains(code) { throw ImportError.noWriteAccess(destination.deletingLastPathComponent().path) }
                        throw ImportError.io("Write error in \(destination.lastPathComponent)", code)
                    }
                    written += w
                }
                total += Int64(n)
                onBytes(Int64(n))
            }
            if fsync(dst) != 0 { throw ImportError.io("Can't flush \(destination.lastPathComponent)", errno) }
        }

        // Verify against the source's size on disk.
        var stSrc = stat(), stTmp = stat()
        guard fstat(src, &stSrc) == 0, stat(tmp, &stTmp) == 0, stSrc.st_size == stTmp.st_size, Int64(stTmp.st_size) == total else {
            throw ImportError.sizeMismatch(source.lastPathComponent)
        }
        // Keep the camera's file dates (Finder / other tools rely on them).
        let attrs = (try? FileManager.default.attributesOfItem(atPath: source.path)) ?? [:]
        var keep: [FileAttributeKey: Any] = [:]
        if let d = attrs[.creationDate] { keep[.creationDate] = d }
        if let d = attrs[.modificationDate] { keep[.modificationDate] = d }
        if !keep.isEmpty { try? FileManager.default.setAttributes(keep, ofItemAtPath: tmp) }

        guard renamex_np(tmp, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ImportError.io("Can't rename to \(destination.lastPathComponent)", errno)
        }
        ok = true
        return total
    }
}

// MARK: - Job

/// One import run. `run` is synchronous — call it off the main thread; `cancel()` from anywhere
/// (stops after the current chunk; what was copied so far is still added to the catalog).
nonisolated final class ImportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    static let insertBatchSize = 24

    /// Imports `candidates` (metadata keyed by primary file path; missing entries are read here).
    /// `progress` is called often from the calling thread — throttle / hop to main yourself.
    func run(_ candidates: [ImportCandidate], metadata: [String: PhotoMetadata], options: ImportOptions,
             catalog: Catalog, importDate: Date = Date(),
             progress: (ImportProgress) -> Void = { _ in }) throws -> ImportResult {
        let start = Date()
        var result = ImportResult(importDate: importDate)
        var p = ImportProgress()
        p.filesTotal = candidates.reduce(0) { $0 + $1.files.count }
        p.bytesTotal = options.mode == .copy ? candidates.reduce(0) { $0 + $1.totalSize } : 0

        if options.mode == .copy {
            guard let dest = options.destination else { throw ImportError.noDestination }
            try ImportFiles.checkWriteAccess(dest)
        }

        var batch: [Photo] = []
        func flush() throws {
            guard !batch.isEmpty else { return }
            result.photoIDs += try catalog.insertPhotos(batch)
            p.photosAdded = result.photoIDs.count
            batch.removeAll()
        }

        for c in candidates {
            if isCancelled { result.wasCancelled = true; break }
            p.currentFile = c.primary.fileName
            p.elapsed = Date().timeIntervalSince(start)
            progress(p)
            let meta = metadata[c.id] ?? PhotoMetadataReader.read(url: c.primary.url, sidecar: c.sidecar?.url)

            switch options.mode {
            case .addInPlace:
                p.filesDone += c.files.count
                guard let meta else { result.failures.append("\(c.primary.fileName): not a readable image"); continue }
                batch.append(Photo(url: c.primary.url, metadata: meta, importDate: importDate,
                                   sidecarPath: c.sidecar?.url.standardizedFileURL.path))

            case .copy:
                let dest = options.destination!
                let date = ImportScanner.date(of: c.primary, metadata: meta) ?? importDate
                let sub = options.pattern.subpath(for: date)
                let dir = sub.isEmpty ? dest : dest.appendingPathComponent(sub, isDirectory: true)
                var copied: [URL] = []
                let bytesBefore = p.bytesDone
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let base = ImportFiles.uniqueBaseName(c.primary.url.deletingPathExtension().lastPathComponent,
                                                          extensions: c.files.map(\.url.pathExtension), in: dir)
                    for f in c.files {
                        let ext = f.url.pathExtension
                        let target = dir.appendingPathComponent(ext.isEmpty ? base : base + "." + ext)
                        _ = try ImportFiles.copy(f.url, to: target, isCancelled: { isCancelled }) { bytes in
                            p.bytesDone += bytes
                            p.elapsed = Date().timeIntervalSince(start)
                            progress(p)
                        }
                        copied.append(target)
                    }
                    p.filesDone += copied.count
                    result.filesCopied += copied.count
                    result.bytesCopied += c.totalSize
                } catch {
                    // All or nothing per photo: remove this candidate's fresh copies (never sources).
                    for url in copied { unlink(url.path) }
                    copied = []
                    if error is CancellationError {
                        result.wasCancelled = true
                    } else if ImportError.isPermission(error) {
                        result.stopError = .noWriteAccess(dest.path)
                    } else {
                        result.failures.append("\(c.primary.fileName): \(error)")
                        p.filesDone += c.files.count
                        p.bytesDone = bytesBefore + c.totalSize
                    }
                }
                guard let primaryURL = copied.first else { break } // failed / cancelled (handled below)
                var m = meta ?? PhotoMetadataReader.read(url: primaryURL, sidecar: copied.count > 1 ? copied[1] : nil)
                m?.fileSize = c.primary.fileSize
                guard let m else { result.failures.append("\(c.primary.fileName): not a readable image"); continue }
                batch.append(Photo(url: primaryURL, metadata: m, importDate: importDate,
                                   sidecarPath: copied.count > 1 ? copied[1].standardizedFileURL.path : nil))
            }
            if result.wasCancelled || result.stopError != nil { break }
            if batch.count >= Self.insertBatchSize { try flush() }
        }
        try flush()

        // Folder membership.
        if !result.photoIDs.isEmpty {
            var folderID = options.targetFolderID
            if let name = options.newFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                folderID = try catalog.createFolder(name: name, parentID: options.targetFolderID)
            }
            if let folderID {
                try catalog.addPhotos(result.photoIDs, toFolder: folderID)
                result.folderID = folderID
            }
        }
        result.elapsed = Date().timeIntervalSince(start)
        p.elapsed = result.elapsed
        p.currentFile = nil
        progress(p)
        return result
    }

    /// Queues a background preview build job (thumbnails only) for freshly imported photos.
    /// Low priority (the grid's visible requests go first); progress shows in `PreviewActivityView`.
    static func warmPreviews(photoIDs: [Int64]) {
        PreviewService.shared.build(photoIDs: photoIDs, levels: [.thumbnail], title: "Building thumbnails for imported photos")
    }
}
