//
//  DevelopDevScript.swift
//  sloproom
//
//  DevScript helpers (DEBUG): `adjust <key> <value>` sets a develop setting by name, e.g.
//  "adjust shadows 60", "adjust temperature 3500", "adjust mixer.blue.saturation -100".
//

#if DEBUG
import AppKit
import Foundation

enum DevelopDevScript {
    /// Resizes the main window (top-left fixed) so tall inspectors fit in a snapshot.
    static func resizeWindow(_ arg: String) {
        let v = arg.split(separator: " ").compactMap { Double($0) }
        guard v.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        let f = w.frame
        w.setFrame(NSRect(x: f.minX, y: f.maxY - v[1], width: v[0], height: v[1]), display: true)
    }

    /// Scrolls the tallest scroll view in the main window (the develop inspector) to `fraction`.
    static func scrollInspector(_ fraction: Double) {
        guard let root = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.contentView else { return }
        var views: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { views.append(s) }; v.subviews.forEach(walk) }
        walk(root)
        guard let sv = views.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = sv.documentView else { print("DevScript: no scroll view"); return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        let y = doc.isFlipped ? maxY * fraction : maxY * (1 - fraction)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    static func adjust(_ session: DevelopSession?, _ arg: String) {
        guard let session else { return }
        let parts = arg.split(separator: " ").map(String.init)
        guard parts.count == 2, let v = Double(parts[1]) else { print("DevScript: adjust <key> <value>"); return }
        var s = session.settings
        switch parts[0] {
        case "exposure": s.tone.exposure = v
        case "contrast": s.tone.contrast = v
        case "highlights": s.tone.highlights = v
        case "shadows": s.tone.shadows = v
        case "whites": s.tone.whites = v
        case "blacks": s.tone.blacks = v
        case "texture": s.presence.texture = v
        case "clarity": s.presence.clarity = v
        case "dehaze": s.presence.dehaze = v
        case "vibrance": s.presence.vibrance = v
        case "saturation": s.presence.saturation = v
        case "temperature": s.whiteBalance.mode = .custom; s.whiteBalance.temperature = v
        case "tint": s.whiteBalance.mode = .custom; s.whiteBalance.tint = v
        case "vignette": s.effects.vignetteAmount = v
        case "grain": s.effects.grainAmount = v
        default:
            let k = parts[0].split(separator: ".").map(String.init)
            guard k.count == 3, k[0] == "mixer", let band = ColorBand(rawValue: k[1]) else {
                print("DevScript: unknown adjust key \(parts[0])"); return
            }
            switch k[2] {
            case "hue": s.colorMixer[band].hue = v
            case "saturation": s.colorMixer[band].saturation = v
            case "luminance": s.colorMixer[band].luminance = v
            default: print("DevScript: unknown adjust key \(parts[0])"); return
            }
        }
        session.settings = s
    }
}
#endif
