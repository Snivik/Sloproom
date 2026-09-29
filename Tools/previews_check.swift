//
//  previews_check.swift
//  Headless test + timings of the preview system (memory/disk cache, generation, edits,
//  build jobs, clean/regenerate, offline fallback, cancellation, LRU pruning).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/out-previews/previews_check Tools/previews_check.swift
//    /private/tmp/claude-501/out-previews/previews_check [photo-dir] [out-dir]
//
//  Reads sample photos READ-ONLY; writes only into out-dir.
//

import Foundation
import CoreGraphics
import ImageIO

@main
struct PreviewsCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var timings: [(String, String)] = []

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func ms(_ seconds: Double) -> String { String(format: "%8.1f ms", seconds * 1000) }

    static func time<T>(_ label: String, per count: Int = 1, _ body: () async throws -> T) async rethrows -> T {
        let t = Date()
        let r = try await body()
        let dt = Date().timeIntervalSince(t)
        timings.append((label, count > 1 ? "\(ms(dt)) total, \(ms(dt / Double(count))) each (n=\(count))" : ms(dt)))
        return r
    }

    static func files(_ dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let photoDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-previews")
        let catalogDir = outDir.appendingPathComponent("cat-\(Int(Date().timeIntervalSince1970))")
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let catalog = try Catalog.open(at: catalogDir)
        let dngs = try fm.contentsOfDirectory(at: photoDir, includingPropertiesForKeys: nil)
            .filter { PhotoMetadataReader.isRAW(url: $0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let importDate = Date()
        let ids = try catalog.insertPhotos(dngs.compactMap { url in
            PhotoMetadataReader.read(url: url).map { Photo(url: url, metadata: $0, importDate: importDate) }
        })
        print("Catalog \(catalogDir.path): \(ids.count) DNGs")
        let service = PreviewService.shared
        service.configure(catalog: catalog)
        let previewsDir = catalog.cacheDirectory("Previews")
        print("Settings: \(service.settings)")
        var photos = try catalog.photos(ids: ids)

        // MARK: Cold thumbnails (embedded)
        print("Thumbnails")
        let first = photos[0]
        let one = await time("thumbnail cold, 1 photo (embedded)") { await service.load(first, level: .thumbnail) }
        check(one.image.map { max($0.width, $0.height) } == 512, "thumbnail is 512 px long edge")
        let rest = Array(photos.dropFirst())
        let cold = await time("thumbnail cold, concurrent", per: rest.count) {
            await withTaskGroup(of: CGImage?.self) { g in
                for p in rest { g.addTask { await service.image(for: p, level: .thumbnail) } }
                return await g.reduce(into: [CGImage?]()) { $0.append($1) }
            }
        }
        check(cold.allSatisfy { $0 != nil }, "all thumbnails generated")
        check(files(previewsDir).count == photos.count, "one thumbnail file per photo on disk (\(files(previewsDir).count))")

        // MARK: Memory hit
        let memHits = await time("thumbnail memory hit (cachedImage)", per: photos.count) {
            photos.compactMap { service.cachedImage(for: $0, level: .thumbnail) }.count
        }
        check(memHits == photos.count, "memory hits for all")

        // MARK: Warm disk hit
        service.purgeMemoryCache()
        check(service.cachedImage(for: first, level: .thumbnail) == nil, "memory purged")
        _ = await time("thumbnail disk hit, 1 photo") { await service.load(first, level: .thumbnail) }
        service.purgeMemoryCache()
        let disk = await time("thumbnail disk hit, concurrent", per: photos.count) {
            await withTaskGroup(of: CGImage?.self) { g in
                for p in photos { g.addTask { await service.image(for: p, level: .thumbnail) } }
                return await g.reduce(into: [CGImage?]()) { $0.append($1) }
            }
        }
        check(disk.allSatisfy { $0 != nil }, "disk hits for all")

        // MARK: Standard previews
        print("Standard previews")
        let std = await time("standard cold, 1 photo (embedded)") { await service.load(first, level: .standard) }
        check(std.image.map { max($0.width, $0.height) } == 2048, "standard is 2048 px long edge")
        let stdRest = Array(photos.dropFirst().prefix(8))
        _ = await time("standard cold, concurrent", per: stdRest.count) {
            await withTaskGroup(of: CGImage?.self) { g in
                for p in stdRest { g.addTask { await service.image(for: p, level: .standard) } }
                return await g.reduce(into: [CGImage?]()) { $0.append($1) }
            }
        }
        service.purgeMemoryCache()
        _ = await time("standard disk hit, 1 photo") { await service.load(first, level: .standard) }

        // MARK: Edited photo
        print("Edits")
        var edit = EditSettings()
        edit.tone.exposure = 1.5
        let version = try catalog.saveEditSettings(edit, for: first.id)
        let edited = try catalog.photo(id: first.id)!
        check(edited.editVersion == version && edited.hasEdits, "edit saved, edit_version \(version)")
        check(service.cachedImage(for: edited, level: .thumbnail) == nil, "edit_version change misses the memory cache")
        let renderedStd = await time("edited standard (RenderPipeline)") { await service.load(edited, level: .standard) }
        let renderedThumb = await time("edited thumbnail (downsampled from standard)") { await service.load(edited, level: .thumbnail) }
        let edited2 = { () -> Photo in
            var e = edit; e.tone.exposure = -1
            _ = try? catalog.saveEditSettings(e, for: photos[1].id)
            return try! catalog.photo(id: photos[1].id)!
        }()
        let renderedThumbOnly = await time("edited thumbnail (RenderPipeline, no standard)") { await service.load(edited2, level: .thumbnail) }
        check(renderedStd.image != nil && renderedThumb.image != nil && renderedThumbOnly.image != nil, "edited previews rendered")
        // Compare with unedited renders of the same photos (the camera JPEG has a different tone curve).
        if let b = renderedThumb.image, let c = renderedThumbOnly.image,
           let a0 = RenderPipeline.renderCGImage(url: first.url, settings: EditSettings(), maxPixelSize: 512),
           let a1 = RenderPipeline.renderCGImage(url: photos[1].url, settings: EditSettings(), maxPixelSize: 512) {
            let (m0, mb, m1, mc) = (mean(a0), mean(b), mean(a1), mean(c))
            print(String(format: "  mean luma photo0 %.3f -> +1.5EV %.3f | photo1 %.3f -> -1EV %.3f", m0, mb, m1, mc))
            check(mb > m0 * 1.3 && mc < m1 * 0.8, "edited thumbnails show the edits")
        }
        let firstFiles = files(previewsDir).filter { $0.lastPathComponent.hasPrefix("\(first.id)_") }.map(\.lastPathComponent).sorted()
        print("  files for photo \(first.id): \(firstFiles)")
        check(firstFiles.count == 2 && firstFiles.allSatisfy { $0.contains("_v\(version)_") }, "old edit_version files replaced (only v\(version) left)")

        // Write a few previews for visual inspection.
        for (name, image) in [("check_thumb_unedited", one.image), ("check_thumb_plus1.5ev", renderedThumb.image),
                              ("check_thumb_minus1ev", renderedThumbOnly.image), ("check_standard_unedited", std.image)] {
            if let image { write(image, to: outDir.appendingPathComponent("\(name).jpg")) }
        }

        // MARK: Eager regeneration after an edit (debounced 1 s, background)
        let third = photos[2]
        var e3 = EditSettings(); e3.presence.saturation = -100; e3.tone.exposure = 0.5
        let v3 = try catalog.saveEditSettings(e3, for: third.id)
        let eagerName = PreviewDiskCache.fileName(photoID: third.id, level: .thumbnail, editVersion: v3,
                                                  signature: service.settings.signature(for: .thumbnail, edited: true))
        let t0 = Date()
        var eagerDone = false
        while Date().timeIntervalSince(t0) < 10 {
            try await Task.sleep(for: .milliseconds(50)) // lets the main queue deliver the notification
            if service.disk!.exists(photoID: third.id, name: eagerName) { eagerDone = true; break }
        }
        timings.append(("eager thumbnail regen after edit (incl. 1 s debounce)", ms(Date().timeIntervalSince(t0))))
        check(eagerDone, "stale thumbnail regenerated eagerly without a request")
        let flagged = photos[3]
        try catalog.setFlag(.pick, for: [flagged.id])
        try await Task.sleep(for: .milliseconds(1500))
        check(files(previewsDir).filter { $0.lastPathComponent.hasPrefix("\(flagged.id)_t_") }.count == 1, "flag change does not regenerate")

        // MARK: Offline originals
        print("Offline")
        let copy = outDir.appendingPathComponent("offline-copy.DNG")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: dngs[4], to: copy)
        let offID = try catalog.insertPhoto(Photo(url: copy, metadata: PhotoMetadataReader.read(url: copy)!, importDate: importDate))
        let off = try catalog.photo(id: offID)!
        check(await service.image(for: off, level: .thumbnail) != nil, "thumbnail of soon-offline photo")
        try fm.removeItem(at: copy)
        service.purgeMemoryCache()
        let offHit = await service.load(off, level: .thumbnail)
        check(offHit.image != nil, "cached preview shown while original is offline")
        var eo = EditSettings(); eo.tone.exposure = 1
        _ = try catalog.saveEditSettings(eo, for: offID)
        let offEdited = try catalog.photo(id: offID)!
        let stale = await time("offline, stale fallback") { await service.load(offEdited, level: .thumbnail) }
        check(stale.image != nil && stale.isOffline, "offline + stale key: older preview + offline flag")
        let offStd = await service.load(offEdited, level: .standard)
        check(offStd.image == nil && offStd.isOffline, "offline + nothing cached: no image, offline flag (no hang)")
        // Access granted / drive back → a roots change makes views of offline photos retry.
        try fm.copyItem(at: dngs[4], to: copy)
        let offRev = PreviewJobs.shared.revision(for: offID)
        _ = try catalog.upsertRoot(path: outDir.path, bookmark: nil)   // posts .roots (main queue)
        for _ in 0..<50 where PreviewJobs.shared.revision(for: offID) == offRev { try? await Task.sleep(for: .milliseconds(20)) }
        check(PreviewJobs.shared.revision(for: offID) != offRev, "roots change bumps the revision of offline photos (ThumbnailView reloads)")
        let back = await service.load(offEdited, level: .standard)
        check(back.image != nil && !back.isOffline, "original back: preview generated, not offline")

        // MARK: Cancellation
        print("Cancellation")
        service.discard(photoIDs: ids)
        service.purgeMemoryCache()
        let tasks = photos.map { p in Task { await service.load(p, level: .standard) } }
        tasks.forEach { $0.cancel() }
        let cancelled = await time("cancel \(tasks.count) standard requests") {
            var n = 0
            for t in tasks where await t.value.image == nil { n += 1 }
            return n
        }
        print("  \(cancelled)/\(tasks.count) returned empty after cancel")
        check(cancelled >= tasks.count - 12, "cancelled requests return promptly without generating")

        // MARK: Build job (regenerate) + clean
        print("Build jobs / clean")
        service.discardAll()
        check(files(previewsDir).isEmpty, "discardAll empties the disk cache")
        check(await service.diskUsage() == 0, "disk usage 0 after clean")
        photos = try catalog.photos(ids: ids)
        await time("build job: thumbnail + standard for all", per: photos.count * 2) {
            PreviewJobs.shared.buildStandard(for: ids)
            while PreviewJobs.shared.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
        }
        check(files(previewsDir).count == photos.count * 2, "build job wrote \(files(previewsDir).count) files for \(photos.count) photos")
        await time("build job again (all present, skipped)", per: photos.count * 2) {
            PreviewJobs.shared.buildStandard(for: ids)
            while PreviewJobs.shared.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
        }
        check(PreviewJobs.shared.done == photos.count * 2 && PreviewJobs.shared.failed == 0, "progress reached total, no failures")
        PreviewJobs.shared.buildAll()
        try await Task.sleep(for: .milliseconds(10))
        PreviewJobs.shared.cancel()
        while PreviewJobs.shared.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
        check(!PreviewJobs.shared.isBusy, "job cancel stops")

        service.discard(photoIDs: [ids[0]])
        check(!files(previewsDir).contains { $0.lastPathComponent.hasPrefix("\(ids[0])_") }, "discard for selection removes that photo's files")
        let revBefore = PreviewJobs.shared.revision(for: ids[1])
        PreviewJobs.shared.regenerate([ids[1]])
        while PreviewJobs.shared.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(50))
        check(PreviewJobs.shared.revision(for: ids[1]) > revBefore, "regenerate bumps the photo's revision (views reload)")
        check(files(previewsDir).filter { $0.lastPathComponent.hasPrefix("\(ids[1])_") }.count == 2, "regenerate rebuilt both levels")

        // MARK: LRU pruning
        print("Pruning")
        let usage = await service.diskUsage()
        let keep = files(previewsDir).first { $0.lastPathComponent.hasPrefix("\(ids[5])_t_") }!
        let oldest = files(previewsDir).filter { $0 != keep }
        for (i, f) in oldest.enumerated() { // make everything else older than `keep`
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(86_400 + i))], ofItemAtPath: f.path)
        }
        let freed = await time("prune to 50 %") { service.disk!.prune(maxBytes: usage / 2) }
        let after = await service.diskUsage()
        print("  usage \(usage) -> \(after) bytes (freed \(freed))")
        check(after <= usage / 2 / 10 * 9 && after > 0, "pruned below 90 % of the limit")
        check(fm.fileExists(atPath: keep.path), "most recently used file survives pruning")

        print("\nTimings (\(ProcessInfo.processInfo.activeProcessorCount) cores)")
        let w = timings.map(\.0.count).max() ?? 0
        for (label, value) in timings { print("  " + label.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + value) }
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Mean luma of a downsampled copy.
    static func mean(_ image: CGImage) -> Double {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
        }
        return sum / Double(w * h) / 255
    }
}
