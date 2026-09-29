//
//  FoldersDevScript.swift
//  sloproom
//
//  Extra `SLOPROOM_DEV_SCRIPT` commands (DEBUG only) that synthesize real keyboard / mouse
//  events inside the app (no accessibility permission needed), to verify shortcuts, focus
//  and sidebar interaction headlessly:
//    key <spec>      e.g. key p | key cmd+shift+n | key shift+right | key delete | key return | key escape
//    type <text>     types characters (one key event each)
//    click <x> <y>   left click at window point (top-left origin, points); `dclick` = double click
//    dump            prints source / filter / selection / folders / first responder
//

#if DEBUG
import AppKit
import Foundation

enum FoldersDevScript {
    static func run(_ command: String, _ arg: String, model: AppModel) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else {
            print("DevScript: no window"); return
        }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        switch command {
        case "key": key(arg, window: window)
        case "type": for ch in arg { key(String(ch), window: window) }
        case "click", "dclick":
            let xy = arg.split(separator: " ").compactMap { Double($0) }
            guard xy.count == 2 else { print("DevScript: click x y"); return }
            click(CGPoint(x: xy[0], y: xy[1]), count: command == "dclick" ? 2 : 1, window: window)
        case "dump": dump(model, window: window)
        case "action":
            // Nil-targeted action as a key window would dispatch it (walks the responder chain).
            let handled = window.firstResponder?.tryToPerform(NSSelectorFromString(arg), with: nil) ?? false
            print("DevScript: action \(arg) handled=\(handled)")
        case "row":
            // Selects a sidebar row the way a click does (table views ignore the first click
            // into an inactive window, so `click` can't select rows in headless runs).
            // `row <n>` selects; `row <n> double` also sends the double-click action.
            guard let table = findTable(in: window.contentView) else { print("DevScript: no table"); return }
            let args = arg.split(separator: " ")
            guard let n = args.first.flatMap({ Int($0) }) else { return }
            window.makeFirstResponder(table)
            table.selectRowIndexes([n], byExtendingSelection: false)
            print("DevScript: row \(n) of \(table.numberOfRows) selected=\(table.selectedRow)")
            if args.count > 1, let action = table.doubleAction { NSApp.sendAction(action, to: table.target, from: table) }
        case "whichmenu":
            // Which top-level menu claims a plain key as its key equivalent.
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: arg, charactersIgnoringModifiers: arg, isARepeat: false,
                                     keyCode: keyCodes[arg]?.0 ?? 0)!
            for top in NSApp.mainMenu?.items ?? [] {
                if top.submenu?.performKeyEquivalent(with: e) == true { print("DevScript: '\(arg)' claimed by \(top.title)"); break }
            }
        case "menus":
            for top in NSApp.mainMenu?.items ?? [] {
                for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty {
                    print("DevScript menu: \(top.title) > \(item.title) [\(item.keyEquivalent)] mods=\(item.keyEquivalentModifierMask.rawValue) action=\(item.action.map(NSStringFromSelector) ?? "-") enabled=\(item.isEnabled)")
                }
            }
        default: break
        }
    }

    private static func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = findTable(in: sub) { return t } }
        return nil
    }

    private static let keyCodes: [String: (UInt16, String)] = [
        "delete": (51, "\u{7f}"), "return": (36, "\r"), "escape": (53, "\u{1b}"), "tab": (48, "\t"),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)), "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "a": (0, "a"), "s": (1, "s"), "d": (2, "d"), "f": (3, "f"), "h": (4, "h"), "g": (5, "g"), "z": (6, "z"), "x": (7, "x"),
        "c": (8, "c"), "v": (9, "v"), "b": (11, "b"), "q": (12, "q"), "w": (13, "w"), "e": (14, "e"), "r": (15, "r"),
        "y": (16, "y"), "t": (17, "t"), "o": (31, "o"), "u": (32, "u"), "i": (34, "i"), "p": (35, "p"), "l": (37, "l"),
        "j": (38, "j"), "k": (40, "k"), "n": (45, "n"), "m": (46, "m"), " ": (49, " "),
        "=": (24, "="), "-": (27, "-"), "[": (33, "["), "]": (30, "]"), "\\": (42, "\\"), ";": (41, ";"),
        "'": (39, "'"), ",": (43, ","), ".": (47, "."), "/": (44, "/"), "`": (50, "`"),
        "0": (29, "0"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "5": (23, "5"),
        "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
        "space": (49, " "), "forwarddelete": (117, "\u{f728}"),
    ]

    private static func key(_ spec: String, window: NSWindow) {
        var parts = spec.count == 1 ? [spec] : spec.split(separator: "+").map(String.init)
        let name = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for m in parts {
            switch m {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let lower = name.count == 1 ? name.lowercased() : name
        let (code, chars) = keyCodes[lower] ?? (0, name)
        if name.count > 1, name.hasPrefix("left") || name.hasPrefix("right") || name.hasPrefix("up") || name.hasPrefix("down") { flags.insert(.function) }
        let typed = name.count == 1 ? (flags.contains(.shift) ? name.uppercased() : name) : chars
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: typed,
                                           charactersIgnoringModifiers: name.count == 1 ? name.lowercased() : chars,
                                           isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(e, atStart: false)   // through the queue, like a real key press (local monitors see it)
        }
    }

    private static func click(_ p: CGPoint, count: Int, window: NSWindow) {
        let location = CGPoint(x: p.x, y: window.frame.height - p.y)
        for n in 1...count {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)
            }
            // Controls track the mouse in a nested loop that dequeues the mouse-up, so queue it first.
            if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown) { NSApp.sendEvent(down) }
        }
    }

    private static func dump(_ model: AppModel, window: NSWindow) {
        let state = FolderSidebarState.shared
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        print("DevScript dump: source=\(model.selectedSource) item=\(model.sidebarItem) filter=\(model.filter.flag) photos=\(model.photos.count) "
              + "selection=\(model.selection.count) focused=\(model.focusedPhotoID.map(String.init) ?? "nil") "
              + "flags=\(model.photos.map { $0.flag.rawValue }) renaming=\(state.renamingFolderID.map(String.init) ?? "nil") "
              + "deleting=\(state.pendingDeletion?.title ?? "nil") expanded=\(state.expanded.sorted()) keyWindow=\(NSApp.keyWindow != nil) firstResponder=\(responder) mode=\(model.mode)")
        print("DevScript dump: folders=" + model.folders.map { "\($0.id):\($0.name)<\($0.parentID.map(String.init) ?? "-")#\($0.sortOrder)" }.joined(separator: ", "))
    }
}
#endif
