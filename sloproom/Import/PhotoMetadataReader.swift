//
//  PhotoMetadataReader.swift
//  sloproom
//
//  Reads EXIF / TIFF / pixel metadata with ImageIO (header only; fast, no decode).
//  Shared by the SD-card importer and the Lightroom importer.
//  Caller must already have sandbox access to the file (see SecurityScopeManager).
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PhotoMetadata: Sendable, Hashable {
    /// Pixel dimensions as stored (NOT orientation-corrected). For RAW this is the default crop size.
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// EXIF orientation 1...8.
    var orientation: Int = 1
    /// DateTimeOriginal (+ OffsetTimeOriginal / SubsecTimeOriginal when present; local time zone
    /// otherwise), falling back to TIFF DateTime, then the file's creation date.
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    /// Seconds.
    var shutter: Double?
    var aperture: Double?
    /// mm
    var focalLength: Double?
    var fileSize: Int64 = 0
    /// ImageIO type identifier, e.g. "com.adobe.raw-image", "public.jpeg".
    var typeIdentifier: String?
    /// Raw EXIF capture fields behind `captureDate` (nil when it came from the file date).
    var captureDateTime: String?
    var captureSubsec: String?
    /// EXIF offset ("+02:00") used for `captureDate`; nil = interpreted in the local time zone.
    var captureOffset: String?

    /// RAW + JPEG pairs: some cameras (Leica) write OffsetTimeOriginal only into the JPEG. If this
    /// file has no offset but `sidecar` has one for the same wall-clock time, re-interpret the
    /// capture time with it (otherwise RAW and JPEG differ by the local-vs-camera zone difference).
    mutating func adoptCaptureOffset(from sidecar: PhotoMetadata) {
        guard captureOffset == nil, let offset = sidecar.captureOffset, let local = captureDateTime,
              sidecar.captureDateTime.map({ $0.prefix(16) == local.prefix(16) }) ?? false,
              let date = PhotoMetadataReader.exifDate(local, offset: offset, subsec: captureSubsec) else { return }
        captureDate = date
        captureOffset = offset
    }
}

nonisolated enum PhotoMetadataReader {
    /// Extensions the app treats as photos.
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl",
        "pef", "srw", "3fr", "iiq", "erf", "mos", "x3f", "raw",
    ]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "png"]

    static func isRAW(url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    static func isSupportedImage(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rawExtensions.contains(ext) || imageExtensions.contains(ext)
    }

    /// Returns nil if the file can't be opened as an image.
    static func read(url: URL) -> PhotoMetadata? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var m = PhotoMetadata()
        m.typeIdentifier = CGImageSourceGetType(src) as String?
        m.pixelWidth = int(props[kCGImagePropertyPixelWidth]) ?? 0
        m.pixelHeight = int(props[kCGImagePropertyPixelHeight]) ?? 0
        m.orientation = int(props[kCGImagePropertyOrientation]) ?? int(tiff[kCGImagePropertyTIFFOrientation]) ?? 1
        if !(1...8).contains(m.orientation) { m.orientation = 1 }

        m.cameraMake = clean(tiff[kCGImagePropertyTIFFMake])
        m.cameraModel = clean(tiff[kCGImagePropertyTIFFModel])
        m.lens = clean(exif[kCGImagePropertyExifLensModel]) ?? clean(aux[kCGImagePropertyExifAuxLensModel])
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any] { m.iso = int(isos.first) }
        m.shutter = double(exif[kCGImagePropertyExifExposureTime])
        m.aperture = double(exif[kCGImagePropertyExifFNumber])
        m.focalLength = double(exif[kCGImagePropertyExifFocalLength])

        let resource = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        m.fileSize = Int64(resource?.fileSize ?? 0)
        let fields: [(value: Any?, offset: Any?, subsec: Any?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifOffsetTimeOriginal] ?? exif[kCGImagePropertyExifOffsetTime],
             exif[kCGImagePropertyExifSubsecTimeOriginal]),
            (tiff[kCGImagePropertyTIFFDateTime], exif[kCGImagePropertyExifOffsetTime], nil),
        ]
        for f in fields {
            guard let date = exifDate(f.value, offset: f.offset, subsec: f.subsec) else { continue }
            m.captureDate = date
            m.captureDateTime = (f.value as? String)?.trimmingCharacters(in: .whitespaces)
            m.captureSubsec = clean(f.subsec)
            m.captureOffset = (f.offset as? String).flatMap { timeZone(offset: $0.trimmingCharacters(in: .whitespaces)) != nil ? $0.trimmingCharacters(in: .whitespaces) : nil }
            break
        }
        if m.captureDate == nil { m.captureDate = resource?.creationDate }
        return m
    }

    /// `read(url:)` of a RAW, taking the time-zone offset from its sidecar JPEG when the RAW has none.
    static func read(url: URL, sidecar: URL?) -> PhotoMetadata? {
        guard var m = read(url: url) else { return nil }
        if m.captureOffset == nil, let sidecar, let s = read(url: sidecar) { m.adoptCaptureOffset(from: s) }
        return m
    }

    /// Applies `adoptCaptureOffset` to every RAW in `metadata` (keyed by path) whose same-named
    /// non-RAW sibling (same directory + base name, case-insensitive) is also in `metadata`, or
    /// exists on disk as .jpg / .JPG / .jpeg.
    static func adoptSidecarOffsets(_ metadata: inout [String: PhotoMetadata]) {
        func key(_ path: String) -> String { (path as NSString).deletingPathExtension.lowercased() }
        var siblings: [String: PhotoMetadata] = [:]
        for (path, m) in metadata where !isRAW(url: URL(fileURLWithPath: path)) && m.captureOffset != nil {
            siblings[key(path)] = m
        }
        for (path, m) in metadata where m.captureOffset == nil && isRAW(url: URL(fileURLWithPath: path)) {
            var fixed = m
            if let s = siblings[key(path)] {
                fixed.adoptCaptureOffset(from: s)
            } else {
                let base = (path as NSString).deletingPathExtension
                guard let jpg = ["JPG", "jpg", "jpeg", "JPEG"].map({ base + "." + $0 }).first(where: FileManager.default.fileExists(atPath:)),
                      let s = read(url: URL(fileURLWithPath: jpg)) else { continue }
                fixed.adoptCaptureOffset(from: s)
            }
            metadata[path] = fixed
        }
    }

    // MARK: - Parsing helpers

    /// Parses "yyyy:MM:dd HH:mm:ss" with optional "+HH:MM" offset and sub-second digits.
    static func exifDate(_ value: Any?, offset: Any?, subsec: Any?) -> Date? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), s.count >= 19 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let off = (offset as? String)?.trimmingCharacters(in: .whitespaces), let tz = timeZone(offset: off) {
            f.timeZone = tz
        } else {
            f.timeZone = .current
        }
        guard var date = f.date(from: String(s.prefix(19))) else { return nil }
        if let sub = (subsec as? String)?.trimmingCharacters(in: .whitespaces), !sub.isEmpty,
           let frac = Double("0." + sub) {
            date += frac
        }
        return date
    }

    private static func timeZone(offset: String) -> TimeZone? {
        // "+02:00" / "-05:30"
        let parts = offset.dropFirst().split(separator: ":")
        guard let sign = offset.first, sign == "+" || sign == "-", parts.count == 2,
              let h = Int(parts[0]), let mm = Int(parts[1]) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + mm * 60))
    }

    private static func clean(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

nonisolated extension Photo {
    /// A not-yet-inserted Photo (id 0) for `url` filled from `metadata`.
    init(url: URL, metadata m: PhotoMetadata, importDate: Date = Date(), sidecarPath: String? = nil) {
        self.init(path: url.standardizedFileURL.path, fileName: url.lastPathComponent)
        fileSize = m.fileSize
        captureDate = m.captureDate
        self.importDate = importDate
        width = m.pixelWidth
        height = m.pixelHeight
        orientation = m.orientation
        cameraMake = m.cameraMake
        cameraModel = m.cameraModel
        lens = m.lens
        iso = m.iso
        shutter = m.shutter
        aperture = m.aperture
        focalLength = m.focalLength
        self.sidecarPath = sidecarPath
    }
}
