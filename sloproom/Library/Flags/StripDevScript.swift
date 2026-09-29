//
//  StripDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG only) for selection / filmstrip / flag QA:
//    sdump                       mode, filter, focused index + id, selection indices, scroll offsets
//    sfilter all|picked|rejected|unflagged|notrejected
//    sclick <i> [cmd|shift]      AppModel.click on photo i (same path as a grid / strip click)
//    sflag pick|none|reject      FlagActions.setFlag (the P / U / X menu path, honours auto advance)
//    (auto advance: launch with -photo.autoAdvanceAfterFlag YES; writing the default would persist)
//    sfind <file name>           index of the photo with that file name
//    sdrag x1 y1 x2 y2           synthesized mouse drag (window points, top-left origin)
//    scount <folder name>        direct photo count of a folder
//

#if DEBUG
import AppKit
import Foundation

enum StripDevScript {
    static let commands: Set<String> = ["sdump", "sfilter", "sclick", "sflag", "sfind", "sdrag", "scount"]

    static func run(_ command: String, _ arg: String, model: AppModel) {
        switch command {
        case "sdump": dump(model)
        case "sfilter":
            let map: [String: FlagFilter] = ["all": .all, "picked": .picked, "rejected": .rejected,
                                             "unflagged": .unflagged, "notrejected": .notRejected]
            if let f = map[arg] { model.filter.flag = f } else { print("DevScript: sfilter \(map.keys.sorted())") }
        case "sclick":
            let parts = arg.split(separator: " ")
            guard let i = parts.first.flatMap({ Int($0) }), model.photos.indices.contains(i) else { print("DevScript: sclick <i> [cmd|shift]"); return }
            let mods = parts.dropFirst().joined()
            model.click(photoID: model.photos[i].id, command: mods.contains("cmd"), shift: mods.contains("shift"))
        case "sflag":
            FlagActions.setFlag(arg == "pick" ? .pick : arg == "reject" ? .reject : .none, model: model)
        case "sfind":
            print("DevScript sfind: \(arg) -> \(model.photos.firstIndex { $0.fileName == arg }.map(String.init) ?? "nil")")
        case "sdrag":
            let v = arg.split(separator: " ").compactMap { Double($0) }
            guard v.count == 4 else { print("DevScript: sdrag x1 y1 x2 y2"); return }
            drag(from: CGPoint(x: v[0], y: v[1]), to: CGPoint(x: v[2], y: v[3]))
        case "scount":
            if let f = model.folders.first(where: { $0.name == arg }) {
                print("DevScript scount: \(arg) = \(model.folderCounts[f.id] ?? 0)")
            }
        default: break
        }
    }

    private static func drag(from a: CGPoint, to b: CGPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else { return }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: window.frame.height - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // Timed like a real drag: down, then drags every 20 ms, then up (drag sessions need
        // time between events to recognise the gesture).
        Task { @MainActor in
            if let down = event(.leftMouseDown, a) { NSApp.postEvent(down, atStart: false) }
            let steps = 20
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(20))
                let t = Double(i) / Double(steps)
                if let e = event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { NSApp.postEvent(e, atStart: false) }
            }
            try? await Task.sleep(for: .milliseconds(100))
            if let up = event(.leftMouseUp, b) { NSApp.postEvent(up, atStart: false) }
        }
    }

    private static func dump(_ model: AppModel) {
        let focusedIndex = model.focusedPhotoID.flatMap(model.index(of:))
        let selected = model.photos.indices.filter { model.selection.contains(model.photos[$0].id) }
        let name = model.focusedPhoto?.fileName ?? "-"
        let flag = model.focusedPhoto?.flag.rawValue ?? 9
        print("DevScript sdump: mode=\(model.mode) filter=\(model.filter.flag) photos=\(model.photos.count) "
              + "focused=\(focusedIndex.map(String.init) ?? "nil")/\(model.focusedPhotoID.map(String.init) ?? "nil") \(name) flag=\(flag) "
              + "selection=\(compact(selected)) session=\(model.developSession?.photo.id.description ?? "nil") "
              + "targets=\(model.actionTargetIDs.count) scroll=\(scrollOffsets())")
    }

    /// "0-3,7,9-10"
    private static func compact(_ indices: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < indices.count {
            var j = i
            while j + 1 < indices.count, indices[j + 1] == indices[j] + 1 { j += 1 }
            parts.append(i == j ? "\(indices[i])" : "\(indices[i])-\(indices[j])")
            i = j + 1
        }
        return "[" + parts.joined(separator: ",") + "]"
    }

    /// Visible origin of every large scroll view in the main window (grid: y, filmstrip: x).
    private static func scrollOffsets() -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else { return "-" }
        var out: [String] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.frame.width > 200 {
                let o = s.contentView.bounds.origin
                out.append("\(Int(s.frame.width))x\(Int(s.frame.height))@(\(Int(o.x)),\(Int(o.y)))")
            }
            v.subviews.forEach(walk)
        }
        if let c = window.contentView { walk(c) }
        return out.joined(separator: " ")
    }
}
#endif
