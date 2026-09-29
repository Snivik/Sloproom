//
//  foundation_check.swift
//  Headless smoke test of the engine layer (catalog, metadata, edit settings, pipeline, previews).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/foundation-out/foundation_check Tools/foundation_check.swift
//    /private/tmp/claude-501/foundation-out/foundation_check [photo-dir] [out-dir]
//
//  Reads sample photos READ-ONLY; writes only into out-dir.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct FoundationCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let photoDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/foundation-out")
        let catalogDir = outDir.appendingPathComponent("check-catalog-\(Int(Date().timeIntervalSince1970))")

        // MARK: Catalog
        print("Catalog at \(catalogDir.path)")
        let catalog = try Catalog.open(at: catalogDir)
        check(FileManager.default.fileExists(atPath: catalog.databaseURL.path), "database file created")
        check(try catalog.allCropPresets().map(\.name) == ["Instagram Story", "Instagram Post Square", "Vertical 4:5", "Horizontal 3:2"], "crop presets seeded")
        let reopened = try Catalog.open(at: catalogDir) // migrations idempotent
        check(try reopened.totalPhotoCount() == 0, "reopen runs migrations once")
        try catalog.applyMigration(named: "check.v1", sql: "CREATE TABLE check_table(x INTEGER);")
        try catalog.applyMigration(named: "check.v1", sql: "CREATE TABLE check_table(x INTEGER);")
        check(true, "named migration idempotent")

        // MARK: Metadata + insert
        let files = try FileManager.default.contentsOfDirectory(at: photoDir, includingPropertiesForKeys: nil)
            .filter { PhotoMetadataReader.isRAW(url: $0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(6)
        let rootID = try catalog.upsertRoot(path: photoDir.path, bookmark: nil, displayName: photoDir.lastPathComponent)
        let importDate = Date()
        var t = Date()
        let newPhotos: [Photo] = files.compactMap { url in
            guard let m = PhotoMetadataReader.read(url: url) else { return nil }
            let jpg = url.deletingPathExtension().appendingPathExtension("JPG")
            let sidecar = FileManager.default.fileExists(atPath: jpg.path) ? jpg.path : nil
            return Photo(url: url, metadata: m, importDate: importDate, sidecarPath: sidecar)
        }
        print(String(format: "  read metadata of %d files in %.3fs", newPhotos.count, Date().timeIntervalSince(t)))
        if let p = newPhotos.first {
            print("  sample: \(p.fileName) \(p.width)x\(p.height) o=\(p.orientation) \(p.cameraMake ?? "-") \(p.cameraModel ?? "-") | \(p.lens ?? "-") | ISO \(p.iso ?? 0) \(p.shutter ?? 0)s f/\(p.aperture ?? 0) \(p.focalLength ?? 0)mm | \(p.captureDate.map { "\($0)" } ?? "no date") | sidecar \(p.sidecarPath != nil)")
        }
        check(!newPhotos.isEmpty, "found sample RAW files")
        let ids = try catalog.insertPhotos(newPhotos)
        check(ids.count == newPhotos.count && Set(ids).count == ids.count && !ids.contains(0), "insertPhotos returns unique ids")
        check(try catalog.insertPhotos(newPhotos) == ids, "re-insert returns existing ids (upsert by path)")
        check(try catalog.totalPhotoCount() == newPhotos.count, "photo count")
        check(try catalog.photo(id: ids[0])?.rootID == rootID, "root_id filled from covering root")
        check(try catalog.root(for: newPhotos[0].path)?.id == rootID, "root(for:) longest prefix")
        check(try catalog.photoIDExists(path: newPhotos[0].path), "photoIDExists")
        check(try catalog.photos(in: .lastImport).count == newPhotos.count, "lastImport source")

        // MARK: Root ↔ photo path normalization (/private/tmp vs /tmp, trailing slash, ..)
        do {
            let pc = try Catalog.open(at: catalogDir.appendingPathComponent("paths"))
            check(Catalog.normalizedPath("/private/tmp/a/") == "/tmp/a" && Catalog.normalizedPath("/tmp/a/../b") == "/tmp/b"
                  && Catalog.normalizedPath("/private/var/x") == "/var/x" && Catalog.normalizedPath("/Volumes/T9/") == "/Volumes/T9",
                  "normalizedPath strips /private, .., trailing slash")
            let early = try pc.insertPhoto(Photo(path: "/private/tmp/sloproom-norm/card/A.DNG"))
            let r = try pc.upsertRoot(path: "/private/tmp/sloproom-norm/card/", bookmark: nil)
            check(try pc.root(id: r)?.path == "/tmp/sloproom-norm/card", "root stored normalized")
            check(try pc.photo(id: early)?.rootID == r, "upsertRoot attaches /private/… photo to normalized root")
            let late = try pc.insertPhoto(Photo(path: "/private/tmp/sloproom-norm/card/sub/B.DNG"))
            check(try pc.photo(id: late)?.rootID == r, "insertPhoto attaches /private/… photo to normalized root")
            check(try pc.root(for: "/tmp/sloproom-norm/card/C.DNG")?.id == r && pc.root(for: "/tmp/sloproom-normX/C.DNG") == nil,
                  "root(for:) matches either spelling, not sibling prefixes")
        }

        // MARK: Folders
        let trips = try catalog.createFolder(name: "Trips")
        let leica = try catalog.createFolder(name: "Leica", parentID: trips)
        let best = try catalog.createFolder(name: "Best", parentID: leica)
        let other = try catalog.createFolder(name: "Other")
        try catalog.addPhotos(ids.prefix(4), toFolder: leica)
        try catalog.addPhotos(ids.prefix(2), toFolder: best)   // overlaps with leica
        try catalog.addPhotos([ids[5 < ids.count ? 5 : 0]], toFolder: trips)
        check(try catalog.photos(in: .folder(id: leica, includeSubfolders: false)).count == 4, "direct folder photos")
        check(try catalog.photos(in: .folder(id: trips, includeSubfolders: true)).count == min(5, ids.count), "recursive folder photos (distinct)")
        check(try catalog.photoCount(folderID: trips, includeSubfolders: true) == min(5, ids.count), "recursive count")
        check(try catalog.folderPhotoCounts()[leica] == 4, "batched counts")
        do { try catalog.moveFolder(id: trips, toParent: best); check(false, "cycle prevented") }
        catch { check(error is CatalogError, "cycle prevented") }
        try catalog.moveFolder(id: other, toParent: trips, index: 0)
        let kids = try catalog.allFolders().filter { $0.parentID == trips }.sorted { $0.sortOrder < $1.sortOrder }
        check(kids.map(\.id) == [other, leica], "moveFolder reorders siblings")
        try catalog.movePhotos([ids[0]], from: best, to: other)
        check(try catalog.photos(in: .folder(id: other, includeSubfolders: false)).map(\.id) == [ids[0]], "movePhotos")
        try catalog.renameFolder(id: best, to: "Best Of")
        check(try catalog.folder(id: best)?.name == "Best Of", "renameFolder")
        try catalog.deleteFolder(id: leica)
        check(try catalog.folder(id: best) == nil, "deleteFolder cascades to subfolders")
        check(try catalog.totalPhotoCount() == newPhotos.count, "deleteFolder keeps photos")
        let tree = FolderTreeCheck.depth(try catalog.allFolders())
        check(tree == 2, "remaining tree depth 2 (Trips > Other)")

        // MARK: Flags / filters / sort
        try catalog.setFlag(.pick, for: ids.prefix(2))
        try catalog.setFlag(.reject, for: [ids[2]])
        try catalog.setRating(4, for: [ids[0]])
        check(try catalog.photos(in: .all, filter: PhotoFilter(flag: .picked)).count == 2, "picked filter")
        check(try catalog.photos(in: .all, filter: PhotoFilter(flag: .rejected)).count == 1, "rejected filter")
        check(try catalog.photos(in: .all, filter: PhotoFilter(flag: .notRejected)).count == ids.count - 1, "not rejected filter")
        check(try catalog.photos(in: .all, filter: PhotoFilter(flag: .all, minRating: 3)).map(\.id) == [ids[0]], "rating filter")
        let byNameDesc = try catalog.photos(in: .all, sort: PhotoSort(key: .fileName, ascending: false)).map(\.fileName)
        check(byNameDesc == byNameDesc.sorted(by: >), "sort by file name desc")

        // MARK: EditSettings
        var s = EditSettings()
        check(s.isDefault, "default settings are default")
        s.tone.exposure = 1
        s.colorMixer[.blue] = HSLAdjustment(hue: 0, saturation: -20, luminance: 0)
        s.masks = [Mask(shape: .radial(RadialGradientMask()), adjustments: { var a = LocalAdjustments(); a.exposure = 0.5; return a }())]
        let json = s.jsonString() ?? ""
        check(EditSettings.fromJSON(json) == s, "EditSettings JSON round trip")
        check(EditSettings.fromJSON("{}") == EditSettings(), "decode {} -> defaults")
        check(EditSettings.fromJSON(#"{"tone":{"exposure":2}}"#)?.tone.exposure == 2, "partial JSON decodes")
        let v = try catalog.saveEditSettings(s, for: ids[0])
        let saved = try catalog.photo(id: ids[0])
        check(v == 1 && saved?.editVersion == 1 && saved?.editSettings == s, "saveEditSettings bumps edit_version")
        if ids.count > 1 {
            // A new (all-zero) or hidden mask renders like the original but must survive saving.
            var onlyMask = EditSettings()
            onlyMask.masks = [Mask(shape: .radial(RadialGradientMask()), adjustments: LocalAdjustments())]
            onlyMask.masks.append({ var m = Mask(shape: .linear(LinearGradientMask()), adjustments: { var a = LocalAdjustments(); a.exposure = 1; return a }()); m.isEnabled = false; return m }())
            check(onlyMask.isDefault && !onlyMask.isEmpty && EditSettings().isEmpty, "isDefault (render) vs isEmpty (persist)")
            _ = try catalog.saveEditSettings(onlyMask, for: ids[1])
            check(try catalog.photo(id: ids[1])?.editSettings.masks.count == 2, "zero / hidden masks persisted")
            _ = try catalog.saveEditSettings(EditSettings(), for: ids[1])
            check(try catalog.photo(id: ids[1])?.editSettingsJSON == nil, "EditSettings() stored as NULL")
        }

        // MARK: Geometry math
        var g = Geometry()
        g.quarterTurns = 1; g.flipHorizontal = true; g.straightenAngle = 7.5
        g.crop = NormRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let math = GeometryMath(sourceSize: CGSize(width: 6000, height: 4000), geometry: g)
        let p = NormPoint(x: 0.3, y: 0.7)
        let back = math.sourceNormalized(fromFrame: math.frameNormalized(fromSource: p))
        check(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9, "GeometryMath round trip")
        let canvas = CanvasGeometry(imageRect: CGRect(x: 10, y: 20, width: 300, height: 400), sourceSize: math.sourceSize, geometry: g, showsCrop: true)
        let m2 = canvas.maskPoint(fromView: canvas.viewPoint(fromMask: p))
        check(abs(m2.x - p.x) < 1e-9 && abs(m2.y - p.y) < 1e-9, "CanvasGeometry round trip")
        var g1 = Geometry(); g1.quarterTurns = 1
        let tl = GeometryMath(sourceSize: CGSize(width: 6, height: 4), geometry: g1).frameNormalized(fromSource: NormPoint(x: 0, y: 0))
        check(abs(tl.x - 1) < 1e-9 && abs(tl.y) < 1e-9, "one clockwise turn moves top-left to top-right")

        // MARK: Render
        let dng = newPhotos[0].url
        t = Date()
        guard let source = RenderPipeline.makeSource(url: dng) else { check(false, "makeSource"); exit(1) }
        print(String(format: "  makeSource %.3fs, oriented %@, asShot %.0fK tint %.1f", Date().timeIntervalSince(t),
                     "\(source.orientedSize)", source.asShotTemperature ?? 0, source.asShotTint ?? 0))
        let target = CGSize(width: 1200, height: 1200)
        var results: [(String, EditSettings)] = [("render_original", EditSettings())]
        var plus1 = EditSettings(); plus1.tone.exposure = 1
        results.append(("render_exposure_plus1", plus1))
        var warm = EditSettings(); warm.whiteBalance.mode = .custom; warm.whiteBalance.temperature = 9000
        results.append(("render_wb_9000K", warm))
        var cool = EditSettings(); cool.whiteBalance.mode = .custom; cool.whiteBalance.temperature = 3000
        results.append(("render_wb_3000K", cool))
        var means: [String: (Double, Double, Double)] = [:]
        for (name, settings) in results {
            t = Date()
            guard let cg = RenderPipeline.renderCGImage(source: source, settings: settings, targetSize: target) else {
                check(false, "render \(name)"); continue
            }
            let url = outDir.appendingPathComponent("\(name).jpg")
            writeJPEG(cg, to: url)
            means[name] = meanRGB(cg)
            print(String(format: "  %@: %dx%d in %.3fs -> %@  mean rgb %.3f %.3f %.3f", name, cg.width, cg.height,
                         Date().timeIntervalSince(t), url.path, means[name]!.0, means[name]!.1, means[name]!.2))
        }
        if let o = means["render_original"], let e = means["render_exposure_plus1"] {
            check(e.0 + e.1 + e.2 > (o.0 + o.1 + o.2) * 1.2, "+1 EV is brighter")
        }
        if let w = means["render_wb_9000K"], let c = means["render_wb_3000K"] {
            check(w.0 / w.2 > c.0 / c.2, "higher temperature renders warmer (R/B ratio)")
        }
        // Non-RAW path (paired JPG) through the same pipeline.
        if let side = newPhotos[0].sidecarURL, let jsrc = RenderPipeline.makeSource(url: side),
           let jcg = RenderPipeline.renderCGImage(source: jsrc, settings: plus1, targetSize: target) {
            writeJPEG(jcg, to: outDir.appendingPathComponent("render_jpg_exposure_plus1.jpg"))
            check(jcg.width == 1200 || jcg.height == 1200, "non-RAW source renders at target size")
        }

        // MARK: Previews
        PreviewService.shared.configure(catalog: catalog)
        let all = try catalog.photos(in: .all)
        t = Date()
        let thumbs = await withTaskGroup(of: CGImage?.self) { group in
            for p in all { group.addTask { await PreviewService.shared.image(for: p, level: .thumbnail) } }
            var r: [CGImage?] = []
            for await x in group { r.append(x) }
            return r
        }
        print(String(format: "  %d thumbnails in %.3fs (one is edited -> rendered)", thumbs.compactMap { $0 }.count, Date().timeIntervalSince(t)))
        check(thumbs.allSatisfy { $0 != nil }, "thumbnails generated")
        check(PreviewService.shared.cachedImage(for: all[0], level: .thumbnail) != nil, "thumbnail cached")

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func meanRGB(_ image: CGImage) -> (Double, Double, Double) {
        let ci = CIImage(cgImage: image)
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [Float](repeating: 0, count: 4)
        RenderPipeline.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      format: .RGBAf, colorSpace: RenderPipeline.sRGB)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }
}

enum FolderTreeCheck {
    static func depth(_ folders: [Folder]) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        return folders.map { f -> Int in
            var d = 1, c = f.parentID
            while let id = c { d += 1; c = byID[id]?.parentID }
            return d
        }.max() ?? 0
    }
}
