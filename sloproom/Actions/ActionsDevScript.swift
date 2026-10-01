//
//  ActionsDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG), routed from DevScript as `act <subcommand>`:
//    act dump                       mode, targets, every registry action's title / availability, undo state
//    act menu <index>               the context-menu entries for a right-click on photo <index> (registry, as built)
//    act run <action id> [folder]   performs an action on the current targets (folder actions: a folder name)
//    act crop <aspect> [match|written]   Bulk Crop of the targets (aspect: original | <preset name> | W:H)
//    act sheet bulkcrop|sync|paste  opens the real sheet for the targets
//    act sheetset aspect <original|preset name|W:H> | orient match|written   (Bulk Crop sheet choices)
//    act sheetapply [sections]      applies the open sheet (Sync / Paste: comma-separated sections or "default")
//    act sheetclose
//    act confirm | act cancel        the pending Reset Edits / Remove from Catalog confirmation
//    act copy                       Copy Settings from the targets (one photo)
//    act undo | act redo            Edit > Undo / Redo routing (same code as the menu items)
//    act wait                       waits until bulk operations finished (+ 0.3 s)
//    act crops                      listed photos: title, flag, crop rect, crop aspect in pixels, preset, edit version
//    act rclick <x> <y> <png>       real right-click (window points, top-left origin): captures the open context
//                                   menu with the window into <png>, prints its items (enabled / tooltip), closes it
//    act toolbarmenu <png>          opens Develop's "Photo Actions" toolbar menu the same way
//    act snapall <png>              all on-screen windows of the app (main window + sheet / dialog) in one PNG
//    act stripdrag <index> <plain|cmd|opt> <folder>   the filmstrip cell's drag payload (PhotoDrag.provider, as a
//                                   real drag start builds it), dropped on <folder> through SwiftUI's drop destination
//

#if DEBUG
import AppKit
import Foundation
import SwiftUI

enum ActionsDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let sub = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch sub {
        case "dump": dump(model)
        case "menu":
            guard let i = Int(rest), model.photos.indices.contains(i) else { print("DevScript act: menu <index>"); return }
            let targets = PhotoActions.targets(model: model, clicked: model.photos[i].id)
            printEntries(PhotoActionMenuItems.entries(targets, model: model), targets: targets)
        case "run":
            let p = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let id = p.first.flatMap(PhotoActionID.init(rawValue:)) else { print("DevScript act: run <\(PhotoActionID.allCases.map(\.rawValue).joined(separator: "|"))>"); return }
            let targets = PhotoActions.targets(model: model)
            let spec = PhotoActionSpec.spec(id)
            let a = PhotoActions.availability(spec, targets, model: model)
            guard a.isEnabled else { print("DevScript act: \(id.rawValue) not available: \(a)"); return }
            if spec.isFolderMenu {
                guard p.count > 1, let folder = model.folders.first(where: { $0.name == p[1] }) else { print("DevScript act: no folder"); return }
                PhotoActions.performFolder(id, targets, folderID: folder.id, model: model)
            } else {
                PhotoActions.perform(id, targets, model: model)
            }
            print("DevScript act: ran \(id.rawValue) on \(targets.count) photo(s)")
        case "crop":
            let p = rest.split(separator: " ").map(String.init)
            let choice = BulkCropChoice.shared
            choice.loadPresets(model.catalog)
            var words = p
            if let last = words.last, last == "match" || last == "written" {
                choice.orientation = last == "match" ? .matchPhoto : .asWritten
                words.removeLast()
            }
            setAspect(words.joined(separator: " "), choice)
            guard let options = choice.options else { print("DevScript act: bad aspect"); return }
            let ids = PhotoActions.targets(model: model).ids
            print("DevScript act: bulk crop \(choice.aspectTitle) \(choice.orientation.rawValue) on \(ids.count) photo(s)")
            PhotoActions.bulkCrop(ids, options: options, model: model)
        case "sheet":
            let targets = PhotoActions.targets(model: model)
            switch rest {
            case "bulkcrop": PhotoActions.perform(.bulkCrop, targets, model: model)
            case "sync": PhotoActions.perform(.syncSettings, targets, model: model)
            case "paste": PhotoActions.perform(.pasteSettingsChoose, targets, model: model)
            default: print("DevScript act: sheet bulkcrop|sync|paste")
            }
        case "sheetset":
            let p = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let choice = BulkCropChoice.shared
            if p.first == "aspect", p.count > 1 { setAspect(p[1], choice) }
            if p.first == "orient", p.count > 1 { choice.orientation = p[1] == "written" ? .asWritten : .matchPhoto }
            print("DevScript act: sheet choice \(choice.aspectTitle) \(choice.orientation.rawValue)")
        case "sheetapply":
            let ui = PhotoActionUI.shared
            switch ui.sheet {
            case .bulkCrop(let ids)?:
                let choice = BulkCropChoice.shared
                guard let options = choice.options else { print("DevScript act: bad choice"); return }
                choice.save()
                ui.sheet = nil
                PhotoActions.bulkCrop(ids, options: options, model: model)
            case .syncSettings(let source, let targets)?:
                ui.sheet = nil
                SettingsSectionsSheet.applyForTest(.sync(source: source), targets: targets, sections: sections(rest, default: EditSection.syncDefault), model: model)
            case .pasteSettings(let ids)?:
                ui.sheet = nil
                SettingsSectionsSheet.applyForTest(.paste, targets: ids, sections: sections(rest, default: EditSection.pasteDefault), model: model)
            case nil: print("DevScript act: no sheet")
            }
        case "sheetclose": PhotoActionUI.shared.sheet = nil
        case "confirm":   // presses the destructive button of a pending Reset Edits / Remove from Catalog confirmation
            let ui = PhotoActionUI.shared
            if let ids = ui.pendingReset { ui.pendingReset = nil; PhotoActions.resetEdits(ids, model: model); print("DevScript act: reset \(ids.count)") }
            else if let ids = ui.pendingRemoval { ui.pendingRemoval = nil; FolderActions.removeFromCatalog(ids, model: model); print("DevScript act: removed \(ids.count)") }
            else { print("DevScript act: nothing to confirm") }
        case "cancel":
            PhotoActionUI.shared.pendingReset = nil
            PhotoActionUI.shared.pendingRemoval = nil
        case "copy":
            PhotoActions.performFromMenu(.copySettings, model: model)
            print("DevScript act: copied from \(DevelopClipboard.copiedFrom ?? "nil")")
        case "undo": BulkEditUndo.shared.undo(model: model); print("DevScript act: \(BulkEditUndo.shared.debugDescription)")
        case "redo": BulkEditUndo.shared.redo(model: model); print("DevScript act: \(BulkEditUndo.shared.debugDescription)")
        case "wait":
            for _ in 0..<300 where BulkProgress.shared.running > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
        case "crops": crops(model)
        case "rclick":
            let p = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard p.count == 3, let x = Double(p[0]), let y = Double(p[1]) else { print("DevScript act: rclick x y png"); return }
            MenuCapture.rightClick(at: CGPoint(x: x, y: y), png: p[2])
        case "toolbarmenu": MenuCapture.toolbarMenu(png: rest)
        case "snapall": MenuCapture.capture(rest)   // every on-screen window of the app (sheets, dialogs) in one PNG
        case "stripdrag":
            let p = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard p.count == 3, let i = Int(p[0]), model.photos.indices.contains(i) else { print("DevScript act: stripdrag <index> <plain|cmd|opt> <folder>"); return }
            let provider = PhotoDrag.provider(for: model.photos[i], model: model, selectUnselected: false)
            let payload: SloproomDragPayload? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: String.self) { s, _ in done.resume(returning: s.flatMap(SloproomDragPayload.init(string:))) }
            }
            guard case .photos(let ids)? = payload else { print("DevScript act: no photo payload"); return }
            print("DevScript act: strip drag payload from \(model.photos[i].displayTitle): \(ids.count) photo(s) "
                  + "\(ids.compactMap { model.photo(id: $0)?.displayTitle }) types=\(provider.registeredTypeIdentifiers)")
            await DropTest.run(modifier: p[1], folderName: p[2], model: model, ids: ids)
        default:
            print("DevScript act: dump | menu <i> | run <id> [folder] | crop <aspect> [match|written] | sheet … | sheetset … | sheetapply | "
                  + "sheetclose | copy | undo | redo | wait | crops | rclick x y png | toolbarmenu png | stripdrag i mod folder")
        }
    }

    private static func setAspect(_ text: String, _ choice: BulkCropChoice) {
        let wh = text.split(separator: ":").compactMap { Double($0) }
        if text == "original" { choice.aspect = .original }
        else if wh.count == 2 { choice.aspect = .custom; choice.customWidth = wh[0]; choice.customHeight = wh[1] }
        else if let p = choice.presets.first(where: { $0.name == text }) { choice.aspect = .preset(p.id) }
        else { print("DevScript act: no preset \(text) in \(choice.presets.map(\.name))") }
    }

    private static func sections(_ text: String, default d: Set<EditSection>) -> Set<EditSection> {
        text.isEmpty || text == "default" ? d : (EditSection.decode(text) ?? d)
    }

    private static func dump(_ model: AppModel) {
        let t = PhotoActions.targets(model: model)
        print("DevScript act dump: mode=\(model.mode.rawValue) targets=\(t.ids.compactMap { model.photo(id: $0)?.displayTitle }) "
              + "primary=\(t.primaryID.flatMap { model.photo(id: $0)?.displayTitle } ?? "nil") clipboard=\(DevelopClipboard.copiedFrom ?? "nil") "
              + "pasteSections=\(EditSection.encode(DevelopClipboard.pasteSections))")
        printEntries(PhotoActionMenuItems.entries(t, model: model), targets: t)
        print("DevScript act dump: undo \(BulkEditUndo.shared.debugDescription) sessionDepth=\(model.developSession?.undoDepth ?? -1) "
              + "sessionCanUndo=\(model.developSession?.canUndo ?? false) progress running=\(BulkProgress.shared.running)")
    }

    private static func printEntries(_ entries: [PhotoActionMenuItems.Entry], targets: PhotoActionTargets) {
        print("DevScript act menu: \(targets.count) target(s), mode \(targets.mode.rawValue)")
        for e in entries {
            let state: String
            switch e.availability {
            case .enabled: state = "enabled "
            case .disabled(let why): state = "DISABLED (\(why))"
            case .hidden: state = "hidden"
            }
            print("  [\(e.spec.group)] \(e.spec.title(count: targets.count))\(e.spec.isFolderMenu ? " ▸" : "") — \(state)")
        }
    }

    private static func crops(_ model: AppModel) {
        for (i, p) in model.photos.enumerated().prefix(80) {
            let s = p.editSettings
            let m = CropMath(sourceSize: p.orientedSize, geometry: s.geometry)
            let r = m.pixelRect(s.geometry.crop)
            let c = s.geometry.crop
            print(String(format: "  [%d] %@ flag=%d crop=%.3f,%.3f %.3fx%.3f aspect=%.4f (%@) preset=%@ turns=%d v%d", i, p.displayTitle, p.flag.rawValue,
                         c.x, c.y, c.width, c.height, r.height > 0 ? r.width / r.height : 0, r.height > r.width ? "portrait" : "landscape",
                         s.geometry.cropPresetID.map(String.init) ?? "-", s.geometry.quarterTurns, p.editVersion))
        }
    }
}

/// Opens a real context menu / toolbar menu, captures it together with the main window (own
/// windows only, no screen-recording permission needed), prints its items and closes it.
/// Menu tracking runs a nested event loop: the capture runs from a timer in the common modes.
enum MenuCapture {
    @MainActor static func rightClick(at p: CGPoint, png: String) {
        guard let window = ShortcutDispatcher.shared.mainWindow else { return }
        let location = CGPoint(x: p.x, y: window.frame.height - p.y)
        guard let down = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // The first synthesized right-click after other input is sometimes swallowed: retry once.
        if !whileTracking(png: png, open: { NSApp.sendEvent(down) }) { whileTracking(png: png) { NSApp.sendEvent(down) } }
    }

    @MainActor static func toolbarMenu(png: String) {
        guard let window = ShortcutDispatcher.shared.mainWindow,
              let item = window.toolbar?.items.first(where: { $0.label == "Photo Actions" }) else { print("DevScript act: no Photo Actions toolbar item"); return }
        func control(_ v: NSView?) -> NSControl? {
            guard let v else { return nil }
            if let c = v as? NSControl { return c }
            for s in v.subviews { if let c = control(s) { return c } }
            return nil
        }
        guard let button = control(item.view) else { print("DevScript act: toolbar item has no control (\(String(describing: item.view)))"); return }
        whileTracking(png: png) { button.performClick(nil) }
    }

    @MainActor private static var trackingMenu: NSMenu?

    @discardableResult
    @MainActor private static func whileTracking(png: String, open: () -> Void) -> Bool {
        var observer: NSObjectProtocol?
        var seen = false
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            guard !seen, let menu, menu.supermenu == nil || menu.supermenu !== NSApp.mainMenu else { return }
            seen = true
            MainActor.assumeIsolated { trackingMenu = menu }
            let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let menu = trackingMenu else { return }
                    trackingMenu = nil
                    capture(png)
                    print("DevScript act menu items (\(menu.items.count)):")
                    for item in menu.items {
                        if item.isSeparatorItem { print("  ——"); continue }
                        print("  \(item.title)\(item.submenu != nil ? " ▸" : "") \(item.isEnabled ? "enabled" : "DISABLED")\(item.toolTip.map { " tip=\"\($0)\"" } ?? "")")
                    }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        open()   // returns after tracking ends
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if !seen { print("DevScript act: no menu opened") }
        return seen
    }

    /// The app's on-screen windows (main window + menu) composited into one PNG.
    @MainActor static func capture(_ path: String) {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let ids = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard !ids.isEmpty, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { print("DevScript act: capture unavailable"); return }
        var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let image = unsafeBitCast(sym, to: Fn.self)(.null, array, 1 << 0)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { print("DevScript act: capture failed"); return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("DevScript act: wrote \(path) (\(image.width)x\(image.height), \(ids.count) windows)")
    }
}
#endif
