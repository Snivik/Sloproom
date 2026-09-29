//
//  LightroomCatalogReader.swift
//  sloproom
//
//  Reads the STRUCTURE of a Lightroom Classic catalog (.lrcat, SQLite): root folders, image
//  files + cheap metadata (capture time, orientation, dims, pick, rating, harvested EXIF) and
//  collection sets / collections with their members. Edits are ignored on purpose.
//
//  The .lrcat is never opened in place: `load(copying:)` copies it into a temp directory
//  (Lightroom may hold it open / locked), opens the copy immutable + read-only, reads everything
//  into memory and deletes the copy again. Engine code: no SwiftUI/AppKit.
//

import Foundation
import SQLite3

// MARK: - Snapshot model

nonisolated struct LRRootFolder: Identifiable, Hashable, Sendable {
    /// `AgLibraryRootFolder.id_local`
    var id: Int64
    /// Absolute path, normalized (no trailing slash), e.g. "/Volumes/T9/Lightroom".
    var path: String
    /// Lightroom's display name of the root folder (often just the last path component).
    var name: String
}

nonisolated struct LRImage: Identifiable, Hashable, Sendable {
    /// `Adobe_images.id_local`
    var id: Int64
    var rootFolderID: Int64
    /// Absolute path of the original file.
    var path: String
    var fileName: String
    var captureDate: Date?
    /// EXIF orientation 1...8.
    var orientation: Int = 1
    /// Stored (un-oriented) pixel dimensions, 0 when unknown.
    var width: Int = 0
    var height: Int = 0
    /// 1 pick, -1 reject, 0 none.
    var pick: Int = 0
    /// 0...5
    var rating: Int = 0
    var isVideo = false
    /// Non-nil for virtual copies: the master image id.
    var masterID: Int64?
    /// Paired file recorded by Lightroom (e.g. the camera JPG of a RAW+JPEG pair).
    var sidecarPath: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    var shutter: Double?
    var aperture: Double?
    var focalLength: Double?

    var isVirtualCopy: Bool { masterID != nil }
}

nonisolated enum LRCollectionKind: String, Sendable, Hashable {
    /// Collection set (`com.adobe.ag.library.group`): only holds other collections.
    case set
    case collection
    /// Smart collection: rule based, not imported.
    case smart
    /// The built-in Quick Collection (a system-only regular collection).
    case quick
}

nonisolated struct LRCollection: Identifiable, Hashable, Sendable {
    /// `AgLibraryCollection.id_local`
    var id: Int64
    var name: String
    var parentID: Int64?
    var kind: LRCollectionKind
    /// Member image ids in Lightroom's order (custom order when present, else capture time).
    /// May contain virtual copies.
    var imageIDs: [Int64] = []
}

/// Everything the importer needs from one Lightroom catalog, fully in memory.
nonisolated struct LightroomCatalogSnapshot: Sendable {
    /// File name of the catalog the user picked, e.g. "Lightroom Catalog.lrcat".
    var catalogName: String
    var roots: [LRRootFolder]
    var images: [LRImage]
    var collections: [LRCollection]
    /// Seconds spent copying + reading.
    var loadDuration: TimeInterval = 0

    private(set) var imageIndex: [Int64: Int] = [:]

    init(catalogName: String, roots: [LRRootFolder], images: [LRImage], collections: [LRCollection]) {
        self.catalogName = catalogName
        self.roots = roots
        self.images = images
        self.collections = collections
        imageIndex = Dictionary(images.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func image(id: Int64) -> LRImage? { imageIndex[id].map { images[$0] } }

    /// The image a virtual copy stands for (itself for masters).
    func masterImage(of id: Int64) -> LRImage? {
        guard let image = image(id: id) else { return nil }
        if let master = image.masterID, let m = self.image(id: master) { return m }
        return image
    }

    // Summary counts.
    var masters: [LRImage] { images.filter { !$0.isVirtualCopy } }
    var photoCount: Int { images.reduce(0) { $0 + ($1.isVirtualCopy || $1.isVideo ? 0 : 1) } }
    var videoCount: Int { images.reduce(0) { $0 + (!$1.isVirtualCopy && $1.isVideo ? 1 : 0) } }
    var virtualCopyCount: Int { images.reduce(0) { $0 + ($1.isVirtualCopy ? 1 : 0) } }
    func collections(of kind: LRCollectionKind) -> [LRCollection] { collections.filter { $0.kind == kind } }
}

nonisolated enum LightroomImportError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case notALightroomCatalog

    var description: String {
        switch self {
        case .cannotOpen(let msg): "Could not open the Lightroom catalog: \(msg)"
        case .notALightroomCatalog: "This file is not a Lightroom Classic catalog."
        }
    }
}

// MARK: - Reader

nonisolated enum LightroomCatalogReader {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp", "mpg", "mpeg"]

    /// Default place for the temporary catalog copy (inside the app container when sandboxed).
    static var defaultTempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LightroomImport", isDirectory: true)
    }

    /// Copies the catalog at `url` into `tempDirectory`, reads the copy and deletes it.
    /// The caller must have (sandbox) read access to `url`. The original is never opened.
    static func load(copying url: URL, tempDirectory: URL = defaultTempDirectory) throws -> LightroomCatalogSnapshot {
        let start = Date()
        let fm = FileManager.default
        let dir = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("catalog.lrcat")
        try fm.copyItem(at: url, to: copy)   // APFS clone when on the same volume
        var snapshot = try read(databaseAt: copy)
        snapshot.catalogName = url.lastPathComponent
        snapshot.loadDuration = Date().timeIntervalSince(start)
        return snapshot
    }

    /// Reads a catalog file directly (immutable, read-only). Only use on a private copy.
    static func read(databaseAt url: URL) throws -> LightroomCatalogSnapshot {
        let db = try ReadOnlySQLite(url: url)
        guard try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'AgLibraryRootFolder'", { $0.string(0) }).count == 1 else {
            throw LightroomImportError.notALightroomCatalog
        }

        let roots = try db.query("SELECT id_local, absolutePath, name FROM AgLibraryRootFolder ORDER BY absolutePath") {
            LRRootFolder(id: $0.int(0), path: Catalog.normalizedRootPath($0.string(1)), name: $0.string(2))
        }

        var seen = Set<Int64>()
        let images = try db.query("""
            SELECT i.id_local, fo.rootFolder, r.absolutePath, fo.pathFromRoot, f.baseName, f.extension,
                   f.sidecarExtensions, i.captureTime, i.orientation, i.fileWidth, i.fileHeight, i.pick,
                   i.rating, i.fileFormat, i.masterImage, cm.value, l.value, e.isoSpeedRating,
                   e.shutterSpeed, e.aperture, e.focalLength
            FROM Adobe_images i
            JOIN AgLibraryFile f ON f.id_local = i.rootFile
            JOIN AgLibraryFolder fo ON fo.id_local = f.folder
            JOIN AgLibraryRootFolder r ON r.id_local = fo.rootFolder
            LEFT JOIN AgHarvestedExifMetadata e ON e.image = i.id_local
            LEFT JOIN AgInternedExifCameraModel cm ON cm.id_local = e.cameraModelRef
            LEFT JOIN AgInternedExifLens l ON l.id_local = e.lensRef
            ORDER BY i.id_local
            """) { r -> LRImage? in
            let id = r.int(0)
            guard seen.insert(id).inserted else { return nil }
            let ext = r.string(5)
            let base = r.string(4)
            let dir = joinPath(r.string(2), r.string(3))
            let fileName = ext.isEmpty ? base : "\(base).\(ext)"
            var image = LRImage(id: id, rootFolderID: r.int(1), path: joinPath(dir, fileName), fileName: fileName)
            image.sidecarPath = sidecarExtension(r.stringOrNil(6)).map { joinPath(dir, "\(base).\($0)") }
            image.captureDate = r.stringOrNil(7).flatMap(parseCaptureTime)
            image.orientation = orientation(fromLightroom: r.stringOrNil(8))
            image.width = Int(r.double(9))
            image.height = Int(r.double(10))
            let pick = r.double(11)
            image.pick = pick > 0 ? 1 : pick < 0 ? -1 : 0
            image.rating = min(max(Int(r.double(12)), 0), 5)
            image.isVideo = r.string(13) == "VIDEO" || videoExtensions.contains(ext.lowercased())
            image.masterID = r.intOrNil(14)
            image.cameraModel = r.stringOrNil(15)
            image.lens = r.stringOrNil(16)
            image.iso = r.doubleOrNil(17).map { Int($0.rounded()) }
            // Lightroom stores APEX values: shutter Tv (t = 2^-Tv), aperture Av (N = 2^(Av/2)).
            image.shutter = r.doubleOrNil(18).map { pow(2, -$0) }
            image.aperture = r.doubleOrNil(19).map { (pow(2, $0 / 2) * 10).rounded() / 10 }
            image.focalLength = r.doubleOrNil(20)
            return image
        }.compactMap { $0 }

        var collections = try db.query("""
            SELECT id_local, creationId, name, parent, systemOnly FROM AgLibraryCollection
            WHERE creationId IN ('com.adobe.ag.library.group', 'com.adobe.ag.library.collection',
                                 'com.adobe.ag.library.smart_collection')
            """) { r -> LRCollection in
            let kind: LRCollectionKind
            switch r.string(1) {
            case "com.adobe.ag.library.group": kind = .set
            case "com.adobe.ag.library.smart_collection": kind = .smart
            default: kind = r.double(4) != 0 ? .quick : .collection
            }
            return LRCollection(id: r.int(0), name: r.string(2), parentID: r.intOrNil(3), kind: kind)
        }

        let members = try db.query("""
            SELECT ci.collection, ci.image FROM AgLibraryCollectionImage ci
            LEFT JOIN Adobe_images i ON i.id_local = ci.image
            ORDER BY ci.collection, ci.positionInCollection IS NULL, ci.positionInCollection, i.captureTime, ci.image
            """) { ($0.int(0), $0.int(1)) }
        var membersByCollection: [Int64: [Int64]] = [:]
        for (collection, image) in members { membersByCollection[collection, default: []].append(image) }
        for i in collections.indices { collections[i].imageIDs = membersByCollection[collections[i].id] ?? [] }

        return LightroomCatalogSnapshot(catalogName: url.lastPathComponent, roots: roots, images: images, collections: collections)
    }

    // MARK: - Field decoding

    /// Joins a directory path (with or without trailing slash) and a relative component.
    static func joinPath(_ dir: String, _ component: String) -> String {
        if component.isEmpty { return dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir }
        let c = component.hasSuffix("/") ? String(component.dropLast()) : component
        return dir.hasSuffix("/") ? dir + c : dir + "/" + c
    }

    /// First image-like extension of Lightroom's comma separated `sidecarExtensions` (XMP ignored).
    static func sidecarExtension(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { PhotoMetadataReader.imageExtensions.contains($0.lowercased()) }
    }

    /// Lightroom orientation codes → EXIF orientation. Verified on real data: "AB" = 1, "DA" = 8.
    static func orientation(fromLightroom code: String?) -> Int {
        switch code?.uppercased() {
        case "AB": 1
        case "BA": 2
        case "CD": 3
        case "DC": 4
        case "AD": 5
        case "BC": 6
        case "CB": 7
        case "DA": 8
        default: 1
        }
    }

    /// Parses Lightroom's `captureTime` ("2021-07-30T23:54:00.000", optionally without seconds /
    /// fraction, optionally with "Z" or "±hh:mm"). Without a zone it is local wall-clock time.
    static func parseCaptureTime(_ s: String) -> Date? {
        let chars = Array(s.utf8)
        func number(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= chars.count else { return nil }
            var v = 0
            for c in chars[from..<(from + len)] {
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2) else { return nil }
        var c = DateComponents(year: year, month: month, day: day,
                               hour: number(11, 2) ?? 0, minute: number(14, 2) ?? 0, second: number(17, 2) ?? 0)
        var i = 19
        var fraction = 0.0
        if i < chars.count, chars[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < chars.count, chars[i] >= 48, chars[i] <= 57 {
                fraction += Double(chars[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if i < chars.count {
            if chars[i] == UInt8(ascii: "Z") {
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            } else if chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-"), let h = number(i + 1, 2) {
                let m = number(i + 4, 2) ?? number(i + 3, 2) ?? 0
                let sign = chars[i] == UInt8(ascii: "-") ? -1 : 1
                if let tz = TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60)) { calendar.timeZone = tz }
            }
        }
        c.timeZone = calendar.timeZone
        return calendar.date(from: c)?.addingTimeInterval(fraction)
    }
}

// MARK: - Minimal read-only SQLite access

/// Opens a database with `?immutable=1` + SQLITE_OPEN_READONLY (a plain read-only open fails on
/// Lightroom catalogs, and immutable guarantees SQLite never writes journals next to the file).
private nonisolated final class ReadOnlySQLite {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let uri = url.absoluteString + "?immutable=1"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw LightroomImportError.cannotOpen(msg)
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func query<T>(_ sql: String, _ map: (Row) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LightroomImportError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { result.append(try map(Row(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw LightroomImportError.cannotOpen(String(cString: sqlite3_errmsg(handle))) }
        }
        return result
    }

    struct Row {
        let stmt: OpaquePointer
        func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }
        func int(_ i: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(i)) }
        func intOrNil(_ i: Int) -> Int64? { isNull(i) ? nil : int(i) }
        func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
        func doubleOrNil(_ i: Int) -> Double? { isNull(i) ? nil : double(i) }
        func string(_ i: Int) -> String { stringOrNil(i) ?? "" }
        func stringOrNil(_ i: Int) -> String? {
            guard let c = sqlite3_column_text(stmt, Int32(i)) else { return nil }
            return String(cString: c)
        }
    }
}
