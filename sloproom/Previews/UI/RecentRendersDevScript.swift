//
//  RecentRendersDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG only) for measuring Develop open / navigation latency and preview
//  cache behaviour:
//    rr time next|prev|<index>   in Develop: go to that photo and print how long until the canvas
//                                shows a first image / a sharp image / the source is loaded / the
//                                pipeline render is done (ms since the command)
//    rr stats                    preview + recent-render counters (memory / disk / generated)
//    rr reset                    reset the counters
//    rr dump                     recent-render cache state (count, bytes, memory entries)
//    rr sheet | rr closesheet    shows / closes the preview settings sheet (snapshot it with `snapwin`)
//    rr limit <n> | rr limit reset   sets "Keep last N rendered photos" like the settings view does
//                                (reset = remove the key from UserDefaults)
//    rr clean                    what Settings > Clean Cache runs (PreviewJobs.discardAll)
//

#if DEBUG
import AppKit
import Foundation

enum RecentRendersDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "time": await time(rest, model: model)
        case "stats": printStats()
        case "reset":
            PreviewService.shared.resetStats()
            RecentRenders.shared.resetStats()
            print("DevScript rr: stats reset")
        case "sheet": model.presentedSheet = .previewSettings
        case "closesheet": model.presentedSheet = nil
        case "clean": PreviewJobs.shared.discardAll()
        case "limit":
            if rest == "reset" { UserDefaults.standard.removeObject(forKey: PreviewSettings.Keys.recentRenderCount) }
            else if let n = Int(rest) { UserDefaults.standard.set(n, forKey: PreviewSettings.Keys.recentRenderCount) }
            PreviewService.shared.reloadSettings()
            print("DevScript rr: limit=\(RecentRenders.shared.limit)")
        case "dump": print("DevScript rr dump: \(RecentRenders.shared.debugDescription)")
        default: print("DevScript rr: unknown command \(arg)")
        }
    }

    private static func printStats() {
        for (level, c) in PreviewService.shared.stats.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("DevScript rr stats: previews \(level) memoryHits=\(c.memoryHits) diskReads=\(c.diskReads) generated=\(c.generated) failed=\(c.failed) writeFailures=\(c.writeFailures)")
        }
        print("DevScript rr stats: recent \(RecentRenders.shared.statsDescription)")
        print("DevScript rr stats: prefetch \(RecentRendersPrefetch.shared.statsDescription)")
    }

    private static func time(_ arg: String, model: AppModel) async {
        let start = Date()
        switch arg {
        case "next": model.moveFocus(by: 1)
        case "prev": model.moveFocus(by: -1)
        default:
            guard let i = Int(arg), model.photos.indices.contains(i) else { print("DevScript rr: time next|prev|<index>"); return }
            if model.mode == .develop { model.focusedPhotoID = model.photos[i].id } else { model.openInDevelop(model.photos[i].id) }
        }
        guard let target = model.focusedPhotoID else { return }
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        var first: Int?, firstKind = "", sharp: Int?, loaded: Int?, rendered: Int?
        while Date().timeIntervalSince(start) < 30 {
            if let s = model.developSession, s.photo.id == target {
                if first == nil, s.renderedImage != nil { first = ms(); firstKind = s.isPlaceholder ? "placeholder" : s.imageOrigin.rawValue }
                if sharp == nil, s.renderedImage != nil, !s.isPlaceholder { sharp = ms() }
                if loaded == nil, !s.isLoading { loaded = ms() }
                if rendered == nil, s.imageOrigin == .pipeline || s.recentRenderIsFinal { rendered = ms() }
                if first != nil, sharp != nil, loaded != nil, rendered != nil { break }
                if s.loadError != nil { print("DevScript rr time: load error \(s.loadError ?? "")"); break }
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let name = model.photo(id: target)?.fileName ?? "?"
        print("DevScript rr time: \(arg) photo=\(target) \(name) first=\(first.map(String.init) ?? "-")ms(\(firstKind)) "
              + "sharp=\(sharp.map(String.init) ?? "-")ms loaded=\(loaded.map(String.init) ?? "-")ms "
              + "final=\(rendered.map(String.init) ?? "-")ms")
    }
}
#endif
