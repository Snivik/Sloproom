//
//  VirtualCopyPreviews.swift
//  sloproom
//
//  A new virtual copy renders exactly like its source (same settings AND edit version), so its
//  previews are seeded from the source's instead of being generated again:
//  - disk previews `<sourceID>_<level>_v<editVersion>_<sig>.jpg` → `<copyID>_…` (APFS clones,
//    ≈ 0.1 ms per file); the copy's cache key (id, edit version, signature) then hits at once,
//    also when the original is offline,
//  - the source's recent Develop render (memory, else disk) → stored for the copy, so opening
//    the copy in Develop shows a sharp image immediately.
//  Engine file (no SwiftUI / AppKit).
//

import Foundation
import CoreGraphics

nonisolated enum VirtualCopyPreviews {
    /// Seeds the previews of freshly created copies. Disk part is synchronous (cheap clones);
    /// `PreviewJobs` is told so visible cells reload.
    static func seed(_ copies: [CreatedVirtualCopy], catalog: Catalog,
                     disk: PreviewDiskCache? = PreviewService.shared.disk,
                     recent: RecentRenders = .shared) {
        guard !copies.isEmpty else { return }
        var seeded = Set<Int64>()
        for copy in copies {
            guard let source = try? catalog.photo(id: copy.sourceID), let made = try? catalog.photo(id: copy.id),
                  made.editVersion == source.editVersion, made.editSettingsJSON == source.editSettingsJSON else { continue }
            if let disk, cloneDiskPreviews(from: source.id, to: copy.id, disk: disk) > 0 {
                seeded.insert(copy.id)
            }
            if recent.isEnabled {
                let hash = RecentRenderKey.settingsHash(made.editSettings)
                if let render = recent.memoryRender(photoID: source.id, settingsHash: hash) {
                    recent.store(render.image, key: RecentRenderKey(photoID: copy.id, settingsHash: hash, box: render.key.box))
                } else {
                    let copyID = copy.id
                    recent.loadRender(photoID: source.id, settingsHash: hash) { render in
                        guard let render else { return }
                        recent.store(render.image, key: RecentRenderKey(photoID: copyID, settingsHash: hash, box: render.key.box))
                    }
                }
            }
        }
        if !seeded.isEmpty { PreviewJobs.notifyChanged(seeded) }
    }

    /// Clones the source's cached previews (every level / signature; normally one version per
    /// level — older versions are what an offline original falls back to, for the copy too) to
    /// the copy's names. Returns the number of files written.
    @discardableResult
    static func cloneDiskPreviews(from sourceID: Int64, to copyID: Int64, disk: PreviewDiskCache) -> Int {
        let fm = FileManager.default
        let sourceShard = disk.url(photoID: sourceID, name: "x").deletingLastPathComponent()
        let prefix = "\(sourceID)_"
        guard let names = try? fm.contentsOfDirectory(atPath: sourceShard.path) else { return 0 }
        var written = 0
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".jpg") {
            // <id>_<level>_v<version>_<signature>.jpg
            let rest = name.dropFirst(prefix.count)
            let parts = rest.split(separator: "_", maxSplits: 2)
            guard parts.count == 3, parts[1].hasPrefix("v") else { continue }
            let target = disk.url(photoID: copyID, name: "\(copyID)_\(rest)")
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { continue }
            if (try? fm.copyItem(at: sourceShard.appendingPathComponent(name), to: target)) != nil { written += 1 }
        }
        return written
    }
}
