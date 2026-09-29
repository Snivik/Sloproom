//
//  export_check.swift
//  Headless checks for JPEG export (sloproom/Export/ExportEngine.swift): full-resolution renders
//  with edits baked in, file naming + collision suffixes, pixel size vs GeometryMath, sRGB,
//  Orientation 1, metadata kept, quality → size, offline skip, cancel (no temp files), write probe.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/out-export/export_check Tools/export_check.swift \
//        sloproom/Export/ExportEngine.swift sloproom/Develop/Crop/CropMath.swift
//    /private/tmp/claude-501/out-export/export_check [photo-dir] [out-dir]
//
//  Reads sample photos READ-ONLY (the catalog references them in place); writes only into out-dir.
//  out-dir/look/ gets downscaled copies of the exports next to the Develop-style render (`*_ref.jpg`).
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct ExportCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let photoDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-export")
        let fm = FileManager.default
        for sub in ["cat", "q85", "q40", "cancel", "look", "readonly"] {
            try? fm.removeItem(at: outDir.appendingPathComponent(sub))
        }
        try fm.createDirectory(at: outDir.appendingPathComponent("look"), withIntermediateDirectories: true)

        // MARK: Catalog: A unedited, B exposure +1 + 4:5 crop, C quarter turn + straighten 5° + radial mask
        let catalog = try Catalog.open(at: outDir.appendingPathComponent("cat"))
        func insert(_ name: String, sidecar: String? = nil) throws -> Int64 {
            let url = photoDir.appendingPathComponent(name)
            guard let meta = PhotoMetadataReader.read(url: url) else { throw CatalogError.notFound }
            return try catalog.insertPhoto(Photo(url: url, metadata: meta, importDate: Date(),
                                                 sidecarPath: sidecar.map { photoDir.appendingPathComponent($0).path }))
        }
        let a = try insert("L1090228.DNG", sidecar: "L1090228.JPG")
        let b = try insert("L1090229.DNG", sidecar: "L1090229.JPG")
        let c = try insert("L1090230.DNG", sidecar: "L1090230.JPG")
        let aJPG = try insert("L1090228.JPG")
        var missing = Photo(path: outDir.appendingPathComponent("missing/L0000001.DNG").path, fileName: "L0000001.DNG")
        missing.width = 100; missing.height = 100
        let offline = try catalog.insertPhoto(missing)

        // Oriented full-res sizes (L1090229 / L1090230 are portrait: EXIF orientation 8).
        func orientedSize(_ name: String) -> CGSize { RenderPipeline.makeSource(url: photoDir.appendingPathComponent(name))!.orientedSize }
        let sizes: [Int64: CGSize] = [a: orientedSize("L1090228.DNG"), b: orientedSize("L1090229.DNG"), c: orientedSize("L1090230.DNG")]
        var sb = EditSettings()
        sb.tone.exposure = 1
        let bs = sizes[b]!, aspect45 = 4.0 / 5.0   // centered 4:5 (w:h) crop
        if bs.width / bs.height > aspect45 {
            let w = aspect45 * bs.height / bs.width
            sb.geometry.crop = NormRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = bs.width / aspect45 / bs.height
            sb.geometry.crop = NormRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        _ = try catalog.saveEditSettings(sb, for: b)

        var sc = EditSettings()
        sc.geometry.quarterTurns = 1
        sc.geometry.straightenAngle = 5
        let cm = CropMath(sourceSize: sizes[c]!, geometry: sc.geometry)
        sc.geometry.crop = cm.normRect(cm.maxRect(aspect: cm.frameSize.width / cm.frameSize.height))
        var r = RadialGradientMask()
        r.center = NormPoint(x: 0.5, y: 0.5); r.radiusX = 0.2; r.radiusY = 0.3; r.feather = 40
        var radial = Mask(name: "Center", shape: .radial(r))
        radial.adjustments.exposure = 1.5
        sc.masks = [radial]
        _ = try catalog.saveEditSettings(sc, for: c)

        // MARK: Export q85 (+ an offline photo)
        print("Export q85")
        let q85 = outDir.appendingPathComponent("q85")
        try fm.createDirectory(at: q85, withIntermediateDirectories: true)
        let r85 = runJob(catalog, [a, b, c, offline], q85, quality: 85)
        timings(r85)
        print("  summary: \(r85.summary)")
        check(r85.exported.map(\.url.lastPathComponent) == ["L1090228.jpg", "L1090229.jpg", "L1090230.jpg"],
              "file names = original base + .jpg (\(r85.exported.map(\.url.lastPathComponent)))")
        check(r85.skipped.count == 1 && r85.skipped.first?.reason == .offline && r85.skipped.first?.photoID == offline,
              "offline photo skipped and reported, not fatal")
        check(r85.summary == "3 exported, 1 skipped (offline)", "summary text")
        check(r85.stopError == nil && !r85.wasCancelled, "no stop error")

        let settings: [Int64: EditSettings] = [a: EditSettings(), b: sb, c: sc]
        for file in r85.exported {
            let name = file.url.lastPathComponent
            let src = photoDir.appendingPathComponent(name.replacingOccurrences(of: ".jpg", with: ".DNG"))
            let expected = GeometryMath(sourceSize: sizes[file.photoID]!, geometry: settings[file.photoID]!.geometry).croppedSize
            guard let (props, image) = readJPEG(file.url) else { check(false, "\(name) decodes"); continue }
            check(abs(CGFloat(image.width) - expected.width) <= 1 && abs(CGFloat(image.height) - expected.height) <= 1,
                  String(format: "\(name) %dx%d == GeometryMath cropped full-res %.1fx%.1f (±1)", image.width, image.height, expected.width, expected.height))
            check(image.colorSpace?.name == CGColorSpace.sRGB && (props["ProfileName"] as? String)?.hasPrefix("sRGB") == true,
                  "\(name) color space sRGB (\(props["ProfileName"] ?? "none"))")
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let srcExif = sourceProps(src)[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            check(props[kCGImagePropertyOrientation as String] as? Int == 1 && (tiff["Orientation"] as? Int ?? 1) == 1, "\(name) Orientation = 1")
            check(exif["DateTimeOriginal"] as? String == srcExif["DateTimeOriginal"] as? String && exif["DateTimeOriginal"] != nil,
                  "\(name) DateTimeOriginal preserved (\(exif["DateTimeOriginal"] ?? "nil"))")
            check(exif["OffsetTimeOriginal"] as? String == "+02:00", "\(name) OffsetTimeOriginal from the sidecar JPEG (\(exif["OffsetTimeOriginal"] ?? "nil"))")
            check(exif["PixelXDimension"] as? Int == image.width && exif["PixelYDimension"] as? Int == image.height, "\(name) EXIF pixel dimensions = output size")
            check(tiff["Make"] != nil && tiff["Model"] != nil && exif["LensModel"] != nil && exif["FNumber"] != nil && exif["ExposureTime"] != nil,
                  "\(name) camera, lens, exposure info kept")
            check((props[kCGImagePropertyGPSDictionary as String] as? [String: Any])?["Latitude"] != nil, "\(name) GPS kept")
            check(exif["CFAPattern"] == nil && props["{DNG}"] == nil, "\(name) no RAW-only metadata")
        }
        check(ExportFiles.tempFiles(in: q85).isEmpty, "no temp files after a normal export")

        // MARK: Look + colour vs the Develop render
        print("Develop render comparison (mean abs difference, 8-bit sRGB)")
        for file in r85.exported {
            let name = file.url.deletingPathExtension().lastPathComponent
            let src = RenderPipeline.makeSource(url: photoDir.appendingPathComponent(name + ".DNG"))!
            let ref = RenderPipeline.renderCGImage(source: src, settings: settings[file.photoID]!,
                                                   targetSize: CGSize(width: 1200, height: 1200), colorSpace: RenderPipeline.sRGB)!
            let small = thumbnail(file.url, maxPixelSize: max(ref.width, ref.height))!
            writeJPEG(small, to: outDir.appendingPathComponent("look/\(name)_export.jpg"))
            writeJPEG(ref, to: outDir.appendingPathComponent("look/\(name)_ref.jpg"))
            let d = meanDifference(small, ref)
            check(d < 4, String(format: "\(name) export matches the Develop render (%.2f / 255, sizes %dx%d vs %dx%d)", d, small.width, small.height, ref.width, ref.height))
        }

        // MARK: Collisions: second run + two photos with the same base name in one job
        print("Collisions")
        let again = runJob(catalog, [a, aJPG], q85, quality: 85)
        check(Set(again.exported.map(\.url.lastPathComponent)) == ["L1090228-1.jpg", "L1090228-2.jpg"],
              "second run + same base name get -1, -2 (\(again.exported.map(\.url.lastPathComponent)))")
        check(fm.fileExists(atPath: q85.appendingPathComponent("L1090228.jpg").path), "original L1090228.jpg not overwritten")
        let rawVsJPG = again.exported.first { $0.photoID == aJPG }
        check(rawVsJPG?.pixelWidth == Int(sizes[a]!.width) && rawVsJPG?.pixelHeight == Int(sizes[a]!.height), "the JPG original exports at its full size (\(rawVsJPG?.pixelWidth ?? 0)x\(rawVsJPG?.pixelHeight ?? 0))")

        // MARK: Quality
        print("Quality 40")
        let q40 = outDir.appendingPathComponent("q40")
        try fm.createDirectory(at: q40, withIntermediateDirectories: true)
        let r40 = runJob(catalog, [a, b, c], q40, quality: 40)
        timings(r40)
        for f40 in r40.exported {
            guard let f85 = r85.exported.first(where: { $0.photoID == f40.photoID }) else { continue }
            let ratio = Double(f40.bytes) / Double(f85.bytes)
            check(ratio < 0.6, String(format: "\(f40.url.lastPathComponent) q40 %.1f MB vs q85 %.1f MB (%.0f%%)",
                                      Double(f40.bytes) / 1e6, Double(f85.bytes) / 1e6, ratio * 100))
        }

        // MARK: Cancel
        print("Cancel")
        let cancelDir = outDir.appendingPathComponent("cancel")
        try fm.createDirectory(at: cancelDir, withIntermediateDirectories: true)
        let job = ExportJob(catalog: catalog, photoIDs: [a, b, c, aJPG, a, b, c, aJPG], options: ExportOptions(destination: cancelDir, quality: 85))
        let running = Task.detached { job.run() }
        try await Task.sleep(for: .milliseconds(700))
        job.cancel()
        let t0 = Date()
        let cancelled = await running.value
        print(String(format: "  cancel took effect after %.2f s; %@", Date().timeIntervalSince(t0), cancelled.summary))
        check(cancelled.wasCancelled && cancelled.exported.count < 8, "cancel stops the job early")
        check(ExportFiles.tempFiles(in: cancelDir).isEmpty, "cancel leaves no temp files")
        let left = (try? fm.contentsOfDirectory(atPath: cancelDir.path)) ?? []
        check(left.allSatisfy { readJPEG(cancelDir.appendingPathComponent($0)) != nil } && left.count == cancelled.exported.count,
              "only complete JPEGs remain (\(left))")

        // MARK: Write probe
        print("Write probe")
        let ro = outDir.appendingPathComponent("readonly")
        try fm.createDirectory(at: ro, withIntermediateDirectories: true)
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        var message = ""
        do { try ExportFiles.checkWriteAccess(ro); } catch { message = "\(error)" }
        check(message == "Sloproom doesn't have write access to “\(ro.path)”. Enable User Selected File: Read/Write in Signing & Capabilities.",
              "read-only folder → \(message)")
        let roJob = runJob(catalog, [a], ro, quality: 85)
        check(roJob.exported.isEmpty && roJob.stopError != nil, "export to a read-only folder stops with the message")
        do { try ExportFiles.checkWriteAccess(outDir.appendingPathComponent("nope")); message = "" } catch { message = "\(error)" }
        check(message.contains("is not available"), "missing folder → \(message)")

        print(failures == 0 ? "ALL EXPORT CHECKS PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Helpers

    static func runJob(_ catalog: Catalog, _ ids: [Int64], _ dir: URL, quality: Int) -> ExportResult {
        let t0 = Date()
        let result = ExportJob(catalog: catalog, photoIDs: ids, options: ExportOptions(destination: dir, quality: quality)).run()
        print(String(format: "  %d photos in %.2f s (2 renders in parallel)", ids.count, Date().timeIntervalSince(t0)))
        return result
    }

    static func timings(_ r: ExportResult) {
        for f in r.exported {
            print(String(format: "    %@ %dx%d  render %.2f s  encode+write %.2f s  %.1f MB", f.url.lastPathComponent,
                         f.pixelWidth, f.pixelHeight, f.renderSeconds, f.encodeSeconds, Double(f.bytes) / 1e6))
        }
    }

    static func sourceProps(_ url: URL) -> [String: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] ?? [:]
    }

    static func readJPEG(_ url: URL) -> ([String: Any], CGImage)? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(s) as String? == UTType.jpeg.identifier,
              let img = CGImageSourceCreateImageAtIndex(s, 0, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] else { return nil }
        return (props, img)
    }

    static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    /// Mean absolute RGB difference (0...255) after drawing both into the same small sRGB bitmap.
    static func meanDifference(_ x: CGImage, _ y: CGImage) -> Double {
        let w = 256, h = max(1, Int((256.0 * Double(y.height) / Double(y.width)).rounded()))
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: RenderPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let p = pixels(x), q = pixels(y)
        var sum = 0.0
        for i in stride(from: 0, to: p.count, by: 4) {
            for k in 0..<3 { sum += abs(Double(p[i + k]) - Double(q[i + k])) }
        }
        return sum / Double(w * h * 3)
    }
}
