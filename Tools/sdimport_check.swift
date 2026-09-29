//
//  sdimport_check.swift
//  Headless test of the SD card import engine (scan, RAW+JPEG pairing, duplicates, safe copy,
//  date folders, catalog insert, folder membership, cancel, write-access errors).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/out-sdimport/sdimport_check Tools/sdimport_check.swift \
//        sloproom/Import/ImportEngine.swift sloproom/Import/Catalog+Import.swift
//    /private/tmp/claude-501/out-sdimport/sdimport_check [sample-dir] [out-dir]
//
//  COPIES a few sample DNG+JPG pairs into <out>/fakecard/DCIM/100LEICA (samples are read-only),
//  imports into <out>/dest with a temp catalog, then re-imports to prove duplicates are skipped.
//

import Foundation

@main
struct SDImportCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t = Date()
        let r = try body()
        print(String(format: "  [%.3fs] %@", Date().timeIntervalSince(t), label))
        return r
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let samples = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01")
        let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-sdimport")
        let fm = FileManager.default
        func std(_ u: URL) -> String { u.standardizedFileURL.path } // catalog paths are standardized (/private/tmp → /tmp)
        let card = out.appendingPathComponent("fakecard")
        let dcim = card.appendingPathComponent("DCIM/100LEICA")
        let dest = out.appendingPathComponent("dest")
        let catalogDir = out.appendingPathComponent("catalog")
        // Only ever delete our own outputs.
        for u in [dest, catalogDir] { try? fm.removeItem(at: u) }
        try fm.createDirectory(at: dcim, withIntermediateDirectories: true)

        // MARK: Fake card (copy, never move)
        print("Fake card at \(dcim.path)")
        let pairs = try fm.contentsOfDirectory(atPath: samples.path)
            .filter { $0.uppercased().hasSuffix(".DNG") }
            .filter { fm.fileExists(atPath: samples.appendingPathComponent(($0 as NSString).deletingPathExtension + ".JPG").path) }
            .sorted().prefix(6)
        try time("copy \(pairs.count) sample pairs to fake card (skipped if present)") {
            for dng in pairs {
                for name in [dng, (dng as NSString).deletingPathExtension + ".JPG"] {
                    let to = dcim.appendingPathComponent(name)
                    if !fm.fileExists(atPath: to.path) { try fm.copyItem(at: samples.appendingPathComponent(name), to: to) }
                }
            }
        }
        // A lone JPEG, a hidden file and a video must be handled / ignored.
        let loneJPG = dcim.appendingPathComponent("LONE0001.JPG")
        if !fm.fileExists(atPath: loneJPG.path) {
            try fm.copyItem(at: samples.appendingPathComponent((pairs[0] as NSString).deletingPathExtension + ".JPG"), to: loneJPG)
        }
        fm.createFile(atPath: dcim.appendingPathComponent(".hidden.JPG").path, contents: Data([1, 2, 3]))
        fm.createFile(atPath: dcim.appendingPathComponent("CLIP0001.MOV").path, contents: Data([1, 2, 3]))

        let catalog = try Catalog.open(at: catalogDir)
        PreviewService.shared.configure(catalog: catalog)

        // MARK: Scan
        print("Scan")
        let files = time("enumerate") { ImportScanner.enumerate(card) }
        check(files.count == pairs.count * 2 + 1, "found \(files.count) photo files (hidden + video ignored)")
        let candidates = ImportScanner.candidates(from: files, pairSidecars: true)
        check(candidates.count == pairs.count + 1, "\(candidates.count) candidates with RAW+JPEG pairing")
        check(candidates.filter { $0.sidecar != nil }.count == pairs.count, "every DNG has its JPG as sidecar")
        check(ImportScanner.candidates(from: files, pairSidecars: false).count == files.count, "pairing off → one candidate per file")
        let metadata = time("read metadata (parallel)") { ImportScanner.readMetadata(files) }
        check(metadata.count == files.count, "metadata for all files")
        let paired = candidates.filter { $0.sidecar != nil }
        check(!paired.isEmpty && paired.allSatisfy { c in
            let raw = metadata[c.id], jpg = metadata[c.sidecar!.id]
            return raw?.captureDate != nil && raw?.captureDate == jpg?.captureDate && raw?.captureOffset == jpg?.captureOffset
        }, "RAW capture time uses its JPEG's zone offset (same instant as the JPEG)")
        let rawOnly = PhotoMetadataReader.read(url: paired[0].primary.url), withSidecar = PhotoMetadataReader.read(url: paired[0].primary.url, sidecar: paired[0].sidecar!.url)
        print("    \(paired[0].primary.fileName): offset \(rawOnly?.captureOffset ?? "none") → \(withSidecar?.captureOffset ?? "none"), \(withSidecar?.captureDate.map { "\($0)" } ?? "-")")
        check(withSidecar?.captureDate == metadata[paired[0].sidecar!.id]?.captureDate, "read(url:sidecar:) adopts the sidecar offset")
        var dup = try DuplicateIndex(catalog: catalog)
        check(!candidates.contains { dup.isDuplicate($0.primary, metadata: metadata[$0.id]) }, "nothing is a duplicate in an empty catalog")

        // MARK: Import (copy)
        print("Import → \(dest.path)")
        let options = ImportOptions(mode: .copy, destination: dest, pattern: .yearAndDay, targetFolderID: nil, newFolderName: "SD Card Test")
        var ticks = 0
        let job = ImportJob()
        let result = try time("copy + catalog \(candidates.count) photos") {
            try job.run(candidates, metadata: metadata, options: options, catalog: catalog) { _ in ticks += 1 }
        }
        let mb = Double(result.bytesCopied) / 1_000_000
        print(String(format: "  copied %d files, %.1f MB, %.0f MB/s, %d progress callbacks", result.filesCopied, mb,
                     mb / max(result.elapsed, 0.001), ticks))
        check(result.failures.isEmpty && result.stopError == nil && !result.wasCancelled, "no failures")
        check(result.photoIDs.count == candidates.count, "\(result.photoIDs.count) photos catalogued")
        check(result.filesCopied == files.count, "all \(files.count) files copied")

        print("Destination tree:")
        let tree = (fm.enumerator(atPath: dest.path)?.allObjects as? [String] ?? []).sorted()
        for t in tree { print("    \(t)") }
        check(!tree.contains { $0.hasSuffix(".tmp") }, "no .tmp files left")
        let day = DestinationPattern.yearAndDay.subpath(for: metadata[candidates[0].id]!.captureDate!)
        check(tree.contains(day), "date folder \(day) created")

        print("Catalog rows:")
        let photos = try catalog.photos(ids: result.photoIDs)
        for p in photos {
            let date = p.captureDate.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
            print("    #\(p.id) \(p.path.replacingOccurrences(of: std(dest), with: "<dest>"))  \(p.width)x\(p.height)  \(date)  sidecar=\(p.sidecarPath.map { ($0 as NSString).lastPathComponent } ?? "-")")
        }
        check(photos.allSatisfy { $0.path.hasPrefix(std(dest)) }, "catalog paths point at the copies")
        check(photos.allSatisfy { fm.fileExists(atPath: $0.path) }, "copied files exist")
        check(photos.filter { $0.sidecarPath != nil }.allSatisfy {
            fm.fileExists(atPath: $0.sidecarPath!) && ($0.sidecarPath! as NSString).deletingPathExtension == ($0.path as NSString).deletingPathExtension
        } && photos.filter { $0.sidecarPath != nil }.count == pairs.count, "sidecar JPGs copied next to their DNGs")
        check(Set(photos.map(\.importDate)).count == 1, "one import date for the session")
        check(try catalog.photos(in: .lastImport).count == photos.count, "Previous Import shows them")
        check(photos.allSatisfy { p in
            let src = candidates.first { $0.primary.fileName == p.fileName }!
            return (try? fm.attributesOfItem(atPath: p.path)[.size] as? Int64) == src.primary.fileSize
        }, "sizes match sources")
        if let folderID = result.folderID {
            check(try catalog.folder(id: folderID)?.name == "SD Card Test", "new folder created")
            check(try catalog.photoCount(folderID: folderID) == photos.count, "photos added to folder")
        } else { check(false, "folder created") }

        // MARK: Re-import: duplicates
        print("Re-import")
        dup = try DuplicateIndex(catalog: catalog)
        let files2 = ImportScanner.enumerate(card)
        let cands2 = ImportScanner.candidates(from: files2, pairSidecars: true)
        let meta2 = ImportScanner.readMetadata(files2)
        let dups = cands2.filter { dup.isDuplicate($0.primary, metadata: meta2[$0.id]) }
        check(dups.count == cands2.count, "all \(dups.count)/\(cands2.count) detected as already imported")
        let toImport = cands2.filter { !dup.isDuplicate($0.primary, metadata: meta2[$0.id]) }
        let r2 = try job.run(toImport, metadata: meta2, options: options, catalog: catalog)
        check(r2.photoIDs.isEmpty && r2.filesCopied == 0, "skipping duplicates imports nothing")
        check(try catalog.totalPhotoCount() == photos.count, "catalog count unchanged")

        // Forced re-import (duplicates option off): never overwrite, pairs keep matching names.
        let one = Array(cands2.filter { $0.sidecar != nil }.prefix(1))
        let r3 = try job.run(one, metadata: meta2, options: ImportOptions(mode: .copy, destination: dest, pattern: .yearAndDay), catalog: catalog)
        let forced = try catalog.photos(ids: r3.photoIDs)
        print("    forced: \(forced.map { ($0.path as NSString).lastPathComponent + " + " + (($0.sidecarPath ?? "-") as NSString).lastPathComponent })")
        check(forced.count == 1 && forced[0].path.hasSuffix("-1.DNG") && forced[0].sidecarPath?.hasSuffix("-1.JPG") == true,
              "collision → name-1.DNG + name-1.JPG (original untouched)")

        // MARK: Add in place (second catalog)
        print("Add in place")
        let inPlaceCatalog = try Catalog.open(at: catalogDir.appendingPathComponent("inplace"))
        let r4 = try time("add \(cands2.count) in place") {
            try ImportJob().run(cands2, metadata: meta2, options: ImportOptions(mode: .addInPlace), catalog: inPlaceCatalog)
        }
        let inPlace = try inPlaceCatalog.photos(ids: r4.photoIDs)
        check(inPlace.count == cands2.count && inPlace.allSatisfy { $0.path.hasPrefix(std(card)) }, "in-place photos keep card paths")
        check(inPlace.filter { $0.sidecarPath != nil }.count == pairs.count, "in-place sidecars recorded")
        let dupInPlace = try DuplicateIndex(catalog: inPlaceCatalog)
        check(cands2.allSatisfy { dupInPlace.isDuplicate($0.primary, metadata: nil) }, "same paths → duplicates")

        // MARK: Cancel
        print("Cancel")
        let cancelDest = out.appendingPathComponent("dest-cancel")
        try? fm.removeItem(at: cancelDest)
        let cancelCatalog = try Catalog.open(at: catalogDir.appendingPathComponent("cancel"))
        let cancelJob = ImportJob()
        let r5 = try cancelJob.run(cands2, metadata: meta2, options: ImportOptions(mode: .copy, destination: cancelDest, pattern: .none),
                                   catalog: cancelCatalog) { p in if p.bytesDone > 100_000_000 { cancelJob.cancel() } }
        let left = (try? fm.contentsOfDirectory(atPath: cancelDest.path)) ?? []
        print("    cancelled after \(r5.photoIDs.count) photos; files: \(left.sorted())")
        check(r5.wasCancelled && r5.photoIDs.count < cands2.count, "cancel stops the import")
        check(!left.contains { $0.hasSuffix(".tmp") } && left.count == r5.filesCopied, "no partial / orphan files after cancel")
        check(try cancelCatalog.totalPhotoCount() == r5.photoIDs.count, "completed photos catalogued")

        // MARK: No write access
        print("Write access")
        let ro = out.appendingPathComponent("readonly-dest")
        try? fm.createDirectory(at: ro, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        do {
            _ = try ImportJob().run(one, metadata: meta2, options: ImportOptions(mode: .copy, destination: ro), catalog: cancelCatalog)
            check(false, "read-only destination throws")
        } catch {
            print("    \(error)")
            check(ImportError.isPermission(error) && "\(error)".contains("User Selected File: Read/Write"), "clear no-write-access error")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path)

        // MARK: Previews
        let t = Date()
        ImportJob.warmPreviews(photoIDs: result.photoIDs)   // PreviewService build job (batch API)
        try await Task.sleep(for: .milliseconds(100))
        while await MainActor.run(body: { PreviewJobs.shared.isBusy }) { try await Task.sleep(for: .milliseconds(50)) }
        let built = Date().timeIntervalSince(t)
        var cached = 0
        for photo in photos where await PreviewService.shared.load(photo, level: .thumbnail).image != nil { cached += 1 }
        print(String(format: "  [%.3fs] build job made %d thumbnails (reload from disk %.3fs)", built, cached, Date().timeIntervalSince(t) - built))
        check(cached == photos.count, "thumbnails generated for imported photos")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
