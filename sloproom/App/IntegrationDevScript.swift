//
//  IntegrationDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG only) used by end-to-end QA:
//    activate                         make the app active (synthesized keys need a key window)
//    menu <Top>/<Item>[/<Sub item>]   performs a real menu item by title, e.g. `menu Photo/Copy Settings`,
//                                     `menu Library/Previews/Discard Previews for Selection`
//    folder new <name>[ in <parent>]  FolderActions.newFolder (no inline rename)
//    folder rename <name> to <new>
//    folder add <name> | folder move <name>   selection (actionTargetIDs) → folder (move = from shown folder)
//    folder remove                    remove selection from the shown folder
//    folder delete <name>
//    selectall                        model.selectAll()
//    focus <index>                    focus / select photo n (like `select`), also in Develop
//    devdump                          prints develop session state (tool, geometry, masks, flag)
//    keqv <letter>                    which of window / main menu claims ⇧⌘<letter> as a key equivalent
//    snapwin <png>                    snapshot of the newest visible window (e.g. Settings)
//

#if DEBUG
import AppKit
import Foundation

enum IntegrationDevScript {
    static let commands: Set<String> = ["activate", "menu", "folder", "selectall", "focus", "devdump", "snapwin", "keqv"]

    static func run(_ command: String, _ arg: String, model: AppModel) {
        switch command {
        case "activate":
            NSApp.activate()
            NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        case "menu": performMenu(path: arg.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) })
        case "folder": folder(arg, model: model)
        case "selectall": model.selectAll()
        case "keqv":
            guard let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                    timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: arg.uppercased(),
                    charactersIgnoringModifiers: arg.uppercased(), isARepeat: false, keyCode: 9) else { return }
            print("DevScript keqv: window=\(w.contentView?.performKeyEquivalent(with: e) ?? false) responder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
            for top in NSApp.mainMenu?.items ?? [] where top.submenu?.performKeyEquivalent(with: e) == true {
                print("DevScript keqv: claimed by menu \(top.title)"); break
            }
        case "snapwin":
            let windows = NSApp.windows.filter(\.isVisible).map { "\($0.title)#\($0.windowNumber)" }
            print("DevScript: windows \(windows)")
            guard let w = NSApp.windows.filter({ $0.isVisible && $0.frame.width > 100 }).max(by: { $0.windowNumber < $1.windowNumber }) else { print("DevScript: no other window"); return }
            typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let image = unsafeBitCast(sym, to: CaptureFn.self)(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: arg))
            print("DevScript: wrote \(arg) (\(w.title))")
        case "devdump":
            let responder = (NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") + " active=\(NSApp.isActive)"
            guard let s = model.developSession else { print("DevScript devdump: no session mode=\(model.mode) responder=\(responder)"); return }
            let g = s.settings.geometry
            print("DevScript devdump: photo=\(s.photo.id) tool=\(s.activeTool) turns=\(g.quarterTurns) straighten=\(g.straightenAngle) "
                  + "crop=\(g.crop) grid=\(s.cropTool.gridMode) masks=\(s.settings.masks.count) selectedMask=\(s.selectedMaskID != nil) "
                  + "overlay=\(MaskToolState.shared.showOverlay) flag=\(model.photo(id: s.photo.id)?.flag.rawValue ?? 9) "
                  + "editVersion=\(model.photo(id: s.photo.id)?.editVersion ?? -1) exposure=\(s.settings.tone.exposure) responder=\(responder)")
        case "focus":
            if let i = Int(arg), model.photos.indices.contains(i) { model.focusedPhotoID = model.photos[i].id }
        default: break
        }
    }

    private static func performMenu(path: [String]) {
        var menu = NSApp.mainMenu
        for (n, title) in path.enumerated() {
            guard let m = menu, let index = m.items.firstIndex(where: { $0.title == title }) else {
                print("DevScript: menu item '\(title)' not found"); return
            }
            if n == path.count - 1 {
                m.update()
                let item = m.items[index]
                print("DevScript: menu \(path.joined(separator: " > ")) enabled=\(item.isEnabled)")
                // Async, so an item that runs a modal alert doesn't block the rest of the script.
                if item.isEnabled { DispatchQueue.main.async { m.performActionForItem(at: index) } }
            } else {
                menu = m.items[index].submenu
                menu?.update()
            }
        }
    }

    private static func folderID(_ name: String, model: AppModel) -> Int64? {
        model.folders.first { $0.name == name }?.id
    }

    private static func folder(_ arg: String, model: AppModel) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "new":
            let pieces = rest.components(separatedBy: " in ")
            let parent = pieces.count > 1 ? folderID(pieces[1], model: model) : nil
            _ = FolderActions.newFolder(parentID: parent, model: model)
            // newFolder starts an inline rename with a unique default name; name it directly.
            if let id = FolderSidebarState.shared.renamingFolderID {
                FolderActions.rename(id, to: pieces[0], model: model)
                FolderSidebarState.shared.renamingFolderID = nil
            }
        case "rename":
            let pieces = rest.components(separatedBy: " to ")
            if pieces.count == 2, let id = folderID(pieces[0], model: model) { FolderActions.rename(id, to: pieces[1], model: model) }
        case "add", "move":
            if let id = folderID(rest, model: model) {
                FolderActions.addPhotos(model.actionTargetIDs, to: id, move: verb == "move", model: model)
            }
        case "remove": FolderActions.removeFromShownFolder(model.actionTargetIDs, model: model)
        case "delete": if let id = folderID(rest, model: model) { FolderActions.delete(id, model: model) }
        default: print("DevScript: unknown folder command \(arg)")
        }
    }
}
#endif
