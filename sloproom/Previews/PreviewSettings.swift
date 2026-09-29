//
//  PreviewSettings.swift
//  sloproom
//
//  User preferences for previews, persisted in UserDefaults (the settings view binds the same
//  keys with @AppStorage). Size / quality / source are part of every preview's cache key, so
//  changing them makes existing previews stale; they are regenerated lazily.
//

import Foundation

nonisolated struct PreviewSettings: Sendable, Equatable {
    /// Long edge of `.standard` previews (loupe / develop placeholder).
    var standardSize = 2048
    /// Long edge of `.thumbnail` previews (grid / filmstrip).
    var thumbnailSize = 512
    /// JPEG quality 0...1 of cached previews.
    var quality: Double = 0.7
    /// Unedited photos: use the camera's embedded JPEG instead of rendering the RAW.
    var useEmbeddedPreviews = true
    /// Disk cache limit in GB; 0 = unlimited. Least recently used previews are pruned first.
    var maxCacheGB = 10
    /// Develop: keep the last N full-quality renders ready (`RecentRenders`); 0 = off.
    var recentRenderCount = RecentRenders.defaultLimit

    static let standardSizes = [1024, 1440, 2048, 2560, 2880, 3840]
    static let thumbnailSizes = [256, 384, 512]
    static let qualities: [(title: String, value: Double)] = [("Low", 0.5), ("Medium", 0.7), ("High", 0.85)]
    static let maxCacheOptions = [2, 5, 10, 20, 0]

    enum Keys {
        static let standardSize = "previews.standardSize"
        static let thumbnailSize = "previews.thumbnailSize"
        static let quality = "previews.quality"
        static let useEmbeddedPreviews = "previews.useEmbeddedPreviews"
        static let maxCacheGB = "previews.maxCacheGB"
        static let recentRenderCount = "previews.recentRenderCount"
    }

    static func load(from defaults: UserDefaults = .standard) -> PreviewSettings {
        var s = PreviewSettings()
        if let v = defaults.object(forKey: Keys.standardSize) as? Int, v > 0 { s.standardSize = v }
        if let v = defaults.object(forKey: Keys.thumbnailSize) as? Int, v > 0 { s.thumbnailSize = v }
        if let v = defaults.object(forKey: Keys.quality) as? Double, v > 0, v <= 1 { s.quality = v }
        if let v = defaults.object(forKey: Keys.useEmbeddedPreviews) as? Bool { s.useEmbeddedPreviews = v }
        if let v = defaults.object(forKey: Keys.maxCacheGB) as? Int, v >= 0 { s.maxCacheGB = v }
        if let v = defaults.object(forKey: Keys.recentRenderCount) as? Int { s.recentRenderCount = min(max(v, 0), RecentRenders.maxLimit) }
        return s
    }

    func pixelSize(for level: PreviewLevel) -> Int {
        switch level {
        case .thumbnail: thumbnailSize
        case .standard: standardSize
        }
    }

    var maxCacheBytes: Int64? { maxCacheGB > 0 ? Int64(maxCacheGB) * 1_000_000_000 : nil }

    /// Part of the cache key: everything that changes how a preview of `level` looks.
    /// "e" = embedded camera preview, "r" = rendered through RenderPipeline.
    func signature(for level: PreviewLevel, edited: Bool) -> String {
        "\(pixelSize(for: level))q\(Int((quality * 100).rounded()))\(useEmbeddedPreviews && !edited ? "e" : "r")"
    }
}
