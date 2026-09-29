//
//  ShortcutsDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG) for the shortcut registry and tooltips (see App/DevTools.swift).
//  The tooltip audit itself is Tools/ax_help_audit.swift (an out-of-process Accessibility
//  client: SwiftUI only exposes its full accessibility tree to one):
//    shortcut set <action id> <spec>   rebind through the store (spec: "k", "cmd+shift+e", "none")
//    shortcut record <action id> <spec> as if typed into the Settings recorder (conflict → pending)
//    shortcut confirm | cancel          Reassign / Cancel of a pending recorder conflict
//    shortcut reset <action id> | resetall
//    shortcut dump                      every binding (* = customized), conflicts, registered handlers
//    shortcut search <text>             Settings > Keyboard search field
//    shortcut last                      the dispatcher's last decision ("K → pick in library")
//    toolbar                            the windows' toolbar items (identifier, label, tooltip)
//    settings previews|drives|keyboard  opens Settings on that tab
//    menutree <Top menu>                every item of a menu bar menu with its key equivalent
//    cellsize                           Library thumbnail size (library.cellSize)
//    brushdump                          brush size, cursor radius (pt) and stroke radius at the current zoom
//

#if DEBUG
import AppKit
import Foundation

enum ShortcutsDevScript {
    static let commands: Set<String> = ["shortcut", "settings", "cellsize", "brushdump", "menutree", "toolbar", "segtips"]

    static func run(_ command: String, _ arg: String, model: AppModel) async {
        let words = arg.split(separator: " ").map(String.init)
        let store = ShortcutStore.shared
        switch command {
        case "shortcut":
            let verb = words.first ?? "dump"
            let action = words.count > 1 ? ShortcutAction(rawValue: words[1]) : nil
            let spec = words.count > 2 ? words[2...].joined(separator: " ") : ""
            switch verb {
            case "set":
                guard let action else { print("DevScript shortcut: unknown action \(words.dropFirst().first ?? "")"); return }
                let combo = spec == "none" ? nil : KeyCombo(spec: spec)
                if spec != "none" && combo == nil { print("DevScript shortcut: bad spec \(spec)"); return }
                store.setBinding(combo, for: action)
                print("DevScript shortcut: \(action.id) = \(store.display(action)) conflicts=\(store.conflicts(of: action).map(\.id))")
            case "record":
                guard let action, let combo = KeyCombo(spec: spec) else { print("DevScript shortcut record <action> <spec>"); return }
                ShortcutRecorder.shared.start(action)
                ShortcutRecorder.shared.record(combo, for: action)
                let p = ShortcutRecorder.shared.pending
                print("DevScript shortcut record: \(action.id) \(combo.display) → binding=\(store.display(action)) pending=\(p.map { "\($0.combo.display) used by \($0.conflicts.map(\.id))" } ?? "none") message=\(ShortcutRecorder.shared.message ?? "-")")
            case "confirm":
                ShortcutRecorder.shared.confirmPending()
                print("DevScript shortcut confirm: overrides=\(store.overrides)")
            case "cancel":
                ShortcutRecorder.shared.pending = nil
                ShortcutRecorder.shared.stop()
            case "reset":
                if let action { store.reset(action); print("DevScript shortcut: \(action.id) = \(store.display(action))") }
            case "resetall":
                store.resetAll()
                print("DevScript shortcut: reset all")
            case "search":   // Settings > Keyboard search field
                SettingsNavigation.shared.keyboardSearch = words.dropFirst().joined(separator: " ")
            case "last":
                print("DevScript shortcut last: \(ShortcutDispatcher.shared.lastDispatch)")
            default:
                dump()
            }
        case "settings":
            SettingsNavigation.shared.tab = SettingsTab(rawValue: arg) ?? .previews
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "menutree":
            guard let top = NSApp.mainMenu?.items.first(where: { $0.title == arg })?.submenu else { print("DevScript menutree: no menu \(arg)"); return }
            top.update()
            func walk(_ menu: NSMenu, _ indent: String) {
                for item in menu.items {
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(KeyCombo.modifiers(item.keyEquivalentModifierMask).glyphs)\(item.keyEquivalent.uppercased())]"
                    print("DevScript menutree: \(indent)\(item.isSeparatorItem ? "---" : item.title)\(key)\(item.isEnabled ? "" : " (disabled)")")
                    if let sub = item.submenu { sub.update(); walk(sub, indent + "  ") }
                }
            }
            walk(top, "")
        case "segtips":   // tooltips of every segmented control (debug for segmentHelp)
            func segs(_ v: NSView) -> [NSSegmentedControl] { (v as? NSSegmentedControl).map { [$0] } ?? v.subviews.flatMap(segs) }
            for w in NSApp.windows where w.isVisible {
                var roots: [NSView] = [w.contentView].compactMap { $0 }
                if let frameView = w.contentView?.superview { roots = [frameView] }
                for seg in roots.flatMap(segs) {
                    let tips = (0..<seg.segmentCount).map { "\(seg.label(forSegment: $0) ?? "?")=\(seg.toolTip(forSegment: $0) ?? "nil")" }
                    print("DevScript segtips: \(w.title) \(ObjectIdentifier(seg).hashValue) \(tips)")
                }
            }
        case "toolbar":
            for w in NSApp.windows where w.isVisible {
                for item in w.toolbar?.items ?? [] {
                    print("DevScript toolbar: \(w.title) id=\(item.itemIdentifier.rawValue) label='\(item.label)' tip='\(item.toolTip ?? "")'")
                }
            }
        case "cellsize":
            print("DevScript cellsize: \(UserDefaults.standard.object(forKey: LibraryGridView.cellSizeKey) as? Double ?? 180)")
        case "brushdump":
            let tool = MaskToolState.shared
            var line = "DevScript brushdump: size=\(tool.brushSize) cursorRadius=\(tool.brushScreenRadius)pt"
            if let s = model.developSession {
                let g = s.canvasGeometry(imageRect: ZoomController.develop.imageRect)
                line += String(format: " strokeRadius=%.5f (× image width) zoom=%@ viewScale=%.4f", tool.brushRadius(in: g),
                               CanvasViewport.label(ZoomController.develop.level), g.viewScale)
                if let b = s.selectedMask?.brush { line += " strokes=\(b.strokes.map { String(format: "%.5f", $0.radius) })" }
            }
            print(line)
        default:
            break
        }
    }

    private static func dump() {
        let store = ShortcutStore.shared
        let registered = ShortcutDispatcher.shared.registeredActions
        for action in ShortcutAction.allCases {
            let mark = store.isCustomized(action) ? "*" : " "
            let handler = action.isMenuCommand ? "menu" : (registered.contains(action) ? "handler" : "-")
            print("DevScript shortcut:\(mark) \(action.id) [\(action.scope.rawValue)] \(store.display(action).isEmpty ? "none" : store.display(action)) (\(handler))")
        }
        let conflicts = store.allConflicts
        print("DevScript shortcut: conflicts=\(conflicts.map { "\($0.0.id)/\($0.1.id)" }) overrides=\(store.overrides)")
    }
}
#endif
