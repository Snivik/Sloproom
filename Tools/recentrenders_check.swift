//
//  recentrenders_check.swift
//  Headless test + timings of RecentRenders (Previews/RecentRenders.swift): keys / settings
//  hash, memory + disk store and lookup, coalesced writes, N-photo LRU eviction, stale
//  entries, remove / removeAll, disabled (N = 0), PreviewService integration (Clean Cache,
//  preview disk-cache size excludes Recent/), HEIC vs JPEG encode / decode timings.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/out-recentrenders/recentrenders_check Tools/recentrenders_check.swift
//    /private/tmp/claude-501/out-recentrenders/recentrenders_check [dng] [out-dir]
//
//  Reads the sample photo READ-ONLY; writes only into out-dir.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct RecentRendersCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func ms(_ t: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(t) * 1000) }

    static func main() async throws {
        let args = CommandLine.arguments
        let dng = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01/L1090228.DNG")
        let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-recentrenders")
        let fm = FileManager.default
        let dir = out.appendingPathComponent("run-\(Int(Date().timeIntervalSince1970))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // MARK: A canvas-sized render of a real photo
        print("Render \(dng.lastPathComponent)")
        guard let source = RenderPipeline.makeSource(url: dng) else { print("cannot open \(dng.path)"); exit(1) }
        let box = CGSize(width: 2360, height: 1500)
        var t = Date()
        guard let image = RenderPipeline.renderCGImage(source: source, settings: EditSettings(), targetSize: box) else { exit(1) }
        print("  pipeline render \(image.width)x\(image.height): \(ms(t))")

        // MARK: Formats
        print("Formats (\(RecentRenders.fileExtension) is used)")
        for type in [UTType.heic, UTType.jpeg] {
            let url = dir.appendingPathComponent("bench.\(type.preferredFilenameExtension ?? "img")")
            t = Date()
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { print("  no \(type) encoder"); continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            _ = CGImageDestinationFinalize(dest)
            let enc = ms(t)
            t = Date()
            let decoded = RecentRenders.decode(url: url)
            let dec = ms(t)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("  \(type.preferredFilenameExtension ?? "?"): encode \(enc), decode \(dec), \(size / 1024) KB, \(decoded?.width ?? 0)x\(decoded?.height ?? 0) \(decoded?.colorSpace?.name as String? ?? "?")")
        }

        // MARK: Keys
        print("Keys")
        var edited = EditSettings()
        edited.tone.exposure = 0.7
        let h0 = RecentRenderKey.settingsHash(EditSettings()), h1 = RecentRenderKey.settingsHash(edited)
        check(h0 != h1, "edits change the settings hash")
        check(h1 == RecentRenderKey.settingsHash(EditSettings.fromJSON(edited.jsonString()) ?? EditSettings()), "hash is stable through JSON round trip (catalog save + reload)")
        let key = RecentRenderKey(photoID: 42, settingsHash: h0, box: box)
        check(RecentRenderKey(fileName: key.fileName) == key, "file name round trip (\(key.fileName))")
        check(RecentRenderKey(fileName: "junk.heic") == nil, "foreign files ignored")

        // MARK: Store / lookup
        print("Store / lookup")
        let rr = RecentRenders()
        let recentDir = dir.appendingPathComponent("Recent")
        rr.configure(directory: recentDir, limit: 5)
        rr.store(image, key: key)
        check(rr.memoryRender(photoID: 42, settingsHash: h0)?.image === image, "memory hit right after store")
        check(rr.memoryRender(photoID: 42, settingsHash: h1) == nil, "other settings miss")
        rr.store(image, key: key) // coalesced with the first
        t = Date()
        rr.flush()
        print("  flush (1 write): \(ms(t))")
        var files = try fm.contentsOfDirectory(atPath: recentDir.path).filter { !$0.hasPrefix(".") }
        check(files == [key.fileName], "one file on disk: \(files)")
        check(rr.stats.writes == 1, "two stores of one photo = one write (\(rr.stats.writes))")

        // A fresh instance (next launch) finds it on disk.
        let rr2 = RecentRenders()
        rr2.configure(directory: recentDir, limit: 5)
        check(rr2.contains(photoID: 42, settingsHash: h0), "index loaded from disk")
        check(rr2.memoryRender(photoID: 42, settingsHash: h0) == nil, "not in memory yet")
        t = Date()
        let fromDisk = rr2.render(photoID: 42, settingsHash: h0)
        print("  disk hit (decode): \(ms(t))")
        check(fromDisk?.image.width == image.width && fromDisk?.image.height == image.height && fromDisk?.key == key, "disk hit has the rendered size and key")
        check(rr2.memoryRender(photoID: 42, settingsHash: h0) != nil, "disk hit is kept in memory")
        if let d = fromDisk?.image { check(abs(mean(d) - mean(image)) < 0.01, String(format: "decoded looks like the render (mean %.4f vs %.4f)", mean(d), mean(image))) }

        // Stale: the photo was edited since.
        check(rr2.render(photoID: 42, settingsHash: h1) == nil, "edited settings: miss")
        check(!rr2.contains(photoID: 42, settingsHash: h0), "stale entry dropped")
        files = try fm.contentsOfDirectory(atPath: recentDir.path).filter { !$0.hasPrefix(".") }
        check(files.isEmpty, "stale file deleted")

        // New render of a photo replaces its old file.
        rr2.store(image, key: key); rr2.flush()
        let key2 = RecentRenderKey(photoID: 42, settingsHash: h1, box: box)
        rr2.store(image, key: key2); rr2.flush()
        files = try fm.contentsOfDirectory(atPath: recentDir.path).filter { !$0.hasPrefix(".") }
        check(files == [key2.fileName], "one file per photo after re-render: \(files)")

        // dropStale (edits elsewhere, e.g. Paste Settings)
        rr2.dropStale([(id: 42, settingsHash: h0)])
        check(!rr2.contains(photoID: 42, settingsHash: h1), "dropStale removes renders of other settings")

        // MARK: LRU eviction beyond N
        print("Eviction (N = 5)")
        let small = RecentRenders.downscale(image, to: 400)!
        for id in Int64(100)..<Int64(108) {
            rr2.store(small, key: RecentRenderKey(photoID: id, settingsHash: h0, box: CGSize(width: 400, height: 400)))
            rr2.flush()
            usleep(20_000)
        }
        let usage = rr2.diskUsage
        check(usage.count == 5, "only N photos on disk (\(usage.count))")
        let kept = Set((try fm.contentsOfDirectory(atPath: recentDir.path)).compactMap { RecentRenderKey(fileName: $0)?.photoID })
        check(kept == Set(Int64(103)..<Int64(108)), "least recently stored evicted: kept \(kept.sorted())")
        rr2.limit = 2
        usleep(200_000)
        check(rr2.diskUsage.count == 2, "lowering N evicts (\(rr2.diskUsage.count))")
        check(rr2.debugDescription.contains("memory=2 "), "memory holds at most N renders")
        rr2.limit = 50

        // MARK: Memory bound
        for id in Int64(200)..<Int64(240) { rr2.store(small, key: RecentRenderKey(photoID: id, settingsHash: h0, box: .zero)) }
        check(rr2.debugDescription.contains("memory=\(rr2.memoryCountLimit) "), "memory LRU bounded to \(rr2.memoryCountLimit) entries")

        // MARK: Disabled
        rr2.limit = 0
        usleep(200_000)
        rr2.store(image, key: key)
        check(rr2.memoryRender(photoID: 42, settingsHash: h0) == nil && rr2.diskUsage.count == 0, "N = 0: nothing kept, disk emptied")

        // MARK: Large canvases are stored downscaled (never an exact match)
        rr2.limit = 5
        guard let big = RenderPipeline.renderCGImage(source: source, settings: EditSettings(), targetSize: CGSize(width: 4000, height: 4000)) else { exit(1) }
        let bigKey = RecentRenderKey(photoID: 7, settingsHash: h0, box: CGSize(width: 4000, height: 4000))
        rr2.store(big, key: bigKey); rr2.flush()
        rr2.purgeMemory()
        let bigHit = rr2.render(photoID: 7, settingsHash: h0)
        check(bigHit.map { max($0.image.width, $0.image.height) } == RecentRenders.maxStoredPixelSize && bigHit?.key.box == .zero,
              "renders > \(RecentRenders.maxStoredPixelSize) px stored downscaled, box 0 (not exact)")
        rr2.store(big, key: bigKey)
        let writes = rr2.stats.writes
        rr2.flush()
        check(rr2.stats.writes == writes, "downscaled entry is not rewritten for the same settings")

        // MARK: purgeAll (catalog replaced in-process)
        rr2.store(small, key: RecentRenderKey(photoID: 9, settingsHash: h0, box: .zero)) // pending write
        rr2.purgeAll()
        check(rr2.memoryRender(photoID: 9, settingsHash: h0) == nil && rr2.memoryRender(photoID: 7, settingsHash: h0) == nil, "purgeAll clears memory")
        rr2.flush()
        check(!rr2.contains(photoID: 9, settingsHash: h0), "purgeAll drops pending writes")
        check(rr2.contains(photoID: 7, settingsHash: h0), "purgeAll keeps files (index re-read from disk)")

        // MARK: PreviewService integration
        print("PreviewService")
        let catalog = try Catalog.open(at: dir.appendingPathComponent("cat"))
        let service = PreviewService.shared
        service.configure(catalog: catalog)
        let shared = RecentRenders.shared
        check(shared.directory?.path == catalog.cacheDirectory("Previews").appendingPathComponent("Recent").path, "configured at <catalog>/Previews/Recent")
        check(shared.limit == RecentRenders.defaultLimit || UserDefaults.standard.object(forKey: PreviewSettings.Keys.recentRenderCount) != nil, "default N = \(RecentRenders.defaultLimit)")
        shared.store(image, key: key); shared.flush()
        let previewBytes = await service.diskUsage()
        check(previewBytes == 0, "preview cache size excludes Recent/ (\(previewBytes))")
        let recentUsage = await service.recentRendersUsage()
        check(recentUsage.count == 1 && recentUsage.bytes > 0, "recent usage \(recentUsage)")
        service.discard(photoIDs: [42])
        check(!shared.contains(photoID: 42, settingsHash: h0), "discard(photoIDs:) removes the photo's recent render")
        shared.store(image, key: key); shared.flush()
        service.discardAll()
        check(shared.diskUsage.count == 0 && shared.memoryRender(photoID: 42, settingsHash: h0) == nil, "Clean Cache (discardAll) removes recent renders")
        let limits = service.memoryLimits
        print("  memory limits: thumbnails \(limits.thumbnail / 1_048_576) MB, standard \(limits.standard / 1_048_576) MB")
        check(limits.thumbnail >= 256 * 1_048_576, "thumbnail memory cache holds ≥ 350 thumbnails")

        print(failures == 0 ? "ALL RECENT RENDERS CHECKS PASSED" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    static func mean(_ image: CGImage) -> Double {
        let w = 64, h = 64
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = 0
        for i in 0..<(w * h) { sum += Int(p[i * 4]) + Int(p[i * 4 + 1]) + Int(p[i * 4 + 2]) }
        return Double(sum) / Double(w * h * 3 * 255)
    }
}
