//
//  VirtualCopiesDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG), routed from DevScript as `vc <subcommand>`:
//    vc create                   Photo > Create Virtual Copy on the action targets (selection / focused)
//    vc copyto <folder name>     Copy to Folder ▸ <folder> (action targets)
//    vc newfolder [name]         New Folder with Virtual Copies (then renames it to `name` if given)
//    vc find <title>             select + focus the photo whose title is <title> ("L1090994.DNG", "L1090994 · Copy 1")
//    vc rename <name>            renames the focused virtual copy;  vc renamealert  opens the Rename alert
//    vc remove                   removes the action targets from the catalog (no confirmation), prints what went
//    vc removetitle              the confirmation title "Remove … and its N virtual copies …" for the targets
//    vc dump                     the listed photos: index, id, master, title, flag, edit version, crop, exposure
//    vc dropverb                 PhotoDropVerb for each modifier combination (shown folder vs target)
//    vc dragmask                 logs the drag source's operation masks of the next drag (e.g. after `sdrag`)
//    vc sourcemask               asks every NSDraggingSource view of the main window for its operation masks
//    vc droptest <plain|cmd|opt> <folder>   drops the action targets on a sidebar folder through the
//                                SwiftUI drop destination (fake NSDraggingInfo, copy-only source mask like
//                                SwiftUI's onDrag), prints the returned operations and the outcome
//    vc previews <id>            preview files on disk for a photo id
//

#if DEBUG
import AppKit
import Foundation
import ObjectiveC
import SwiftUI

enum VirtualCopiesDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let sub = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch sub {
        case "create":
            VirtualCopyActions.create(model.actionTargetIDs, model: model)
            print("DevScript vc: focused=\(model.focusedPhoto?.displayTitle ?? "nil") selection=\(model.selection.count) mode=\(model.mode.rawValue)")
        case "copyto":
            guard let folder = model.folders.first(where: { $0.name == rest }) else { print("DevScript vc: no folder \(rest)"); return }
            VirtualCopyActions.copy(model.actionTargetIDs, to: folder.id, model: model)
        case "newfolder":
            let before = Set(model.folders.map(\.id))
            VirtualCopyActions.newFolder(with: model.actionTargetIDs, model: model)
            try? await Task.sleep(for: .milliseconds(300))
            if !rest.isEmpty, let id = model.folders.map(\.id).first(where: { !before.contains($0) })
                ?? FolderSidebarState.shared.renamingFolderID {
                FolderSidebarState.shared.renamingFolderID = nil
                FolderActions.rename(id, to: rest, model: model)
            }
        case "find":
            if let p = model.photos.first(where: { $0.displayTitle == rest || $0.fileName == rest }) {
                model.click(photoID: p.id, command: false, shift: false)
                print("DevScript vc: found \(rest) id=\(p.id) index=\(model.index(of: p.id) ?? -1)")
            } else { print("DevScript vc: no photo titled \(rest)") }
        case "rename":
            if let id = model.focusedPhotoID { VirtualCopyActions.rename(id, to: rest, model: model) }
        case "renamealert":
            VirtualCopyActions.requestRename(model.focusedPhotoID.map { [$0] } ?? [], model: model)
        case "remove":
            let ids = model.actionTargetIDs
            let all = (try? model.catalog.idsIncludingVirtualCopies(ids)) ?? ids
            VirtualCopyActions.removeFromCatalog(ids, model: model)
            print("DevScript vc: removed \(ids) (+ cascaded \(all.count - ids.count): \(all.dropFirst(ids.count).map { $0 }))")
        case "removetitle":
            print("DevScript vc: \(VirtualCopyActions.removalTitle(model.actionTargetIDs, model: model))")
        case "dump": dump(model)
        case "dropverb": dropVerbs(model)
        case "dragmask": DragMaskProbe.install()
        case "sourcemask": DragMaskProbe.querySources()
        case "droptest":   // vc droptest <plain|cmd|opt> <folder name>
            let p = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard p.count == 2 else { print("DevScript vc: droptest <plain|cmd|opt> <folder>"); return }
            await DropTest.run(modifier: p[0], folderName: p[1], model: model)
        case "previews":
            guard let id = Int64(rest), let disk = PreviewService.shared.disk else { return }
            let dir = disk.url(photoID: id, name: "x").deletingLastPathComponent()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("\(id)_") }.sorted()
            let recent = ((try? FileManager.default.contentsOfDirectory(atPath: disk.recentDirectory.path)) ?? []).filter { $0.hasPrefix("\(id)_") }
            print("DevScript vc previews \(id): \(names) recent=\(recent)")
        default:
            print("DevScript vc: create | copyto <folder> | newfolder [name] | find <title> | rename <name> | renamealert | remove | removetitle | dump | dropverb | dragmask | previews <id>")
        }
    }

    private static func dump(_ model: AppModel) {
        let copies = (try? model.catalog.virtualCopyCount()) ?? -1
        print("DevScript vc dump: source=\(model.selectedSource) photos=\(model.photos.count) total=\(model.totalPhotoCount) copies=\(copies) "
              + "focused=\(model.focusedPhoto?.displayTitle ?? "nil") selection=\(model.orderedSelection.compactMap { model.photo(id: $0)?.displayTitle })")
        for (i, p) in model.photos.enumerated().prefix(40) {
            let s = p.editSettings
            let c = s.geometry.crop
            let crop = String(format: "%.3f,%.3f %.3fx%.3f", c.x, c.y, c.width, c.height)
            print("  [\(i)] id=\(p.id) master=\(p.masterID.map(String.init) ?? "-") \(p.displayTitle) flag=\(p.flag.rawValue) v\(p.editVersion) "
                  + "exp=\(s.tone.exposure) crop=\(crop) preset=\(s.geometry.cropPresetID.map(String.init) ?? "-")")
        }
    }

    private static func dropVerbs(_ model: AppModel) {
        let combos: [(String, NSEvent.ModifierFlags)] = [("plain", []), ("cmd", .command), ("opt", .option), ("cmd+opt", [.command, .option])]
        for (shown, target): (Int64?, Int64) in [(nil, 1), (7, 1), (1, 1)] {
            let row = combos.map { name, flags in
                let v = PhotoDropVerb.resolve(flags, shownFolderID: shown, target: target)
                return "\(name)=\(v.rawValue)/\(v.operation)"
            }
            print("DevScript vc dropverb shown=\(shown.map(String.init) ?? "none") target=\(target): \(row.joined(separator: " "))")
        }
    }
}

/// Drives the real AppKit drop destination of a sidebar folder row (SwiftUI's hosting view) with a
/// fake `NSDraggingInfo`: synthetic mouse drags never drop, so this is how drop handling is tested.
enum DropTest {
    @MainActor static func run(modifier: String, folderName: String, model: AppModel) async {
        guard let window = ShortcutDispatcher.shared.mainWindow,
              let folder = model.folders.first(where: { $0.name == folderName }),
              let table = findOutline(window.contentView) else { print("DevScript vc droptest: no window / folder / sidebar"); return }
        let ids = model.actionTargetIDs
        guard !ids.isEmpty else { print("DevScript vc droptest: nothing selected"); return }
        let payload = SloproomDragPayload.photos(ids)
        _ = SloproomDrag.provider(payload)   // records SloproomDrag.current like a real drag start
        let pb = NSPasteboard(name: NSPasteboard.Name("sloproom.droptest.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(payload.string, forType: .string)
        PhotoDropVerb.modifierOverride = modifier == "cmd" ? .command : modifier == "opt" ? .option : []
        defer { PhotoDropVerb.modifierOverride = nil; pb.releaseGlobally() }
        let before = (try? model.catalog.photoCount(folderID: folder.id)) ?? -1
        let copiesBefore = (try? model.catalog.virtualCopyCount()) ?? -1
        // Find the row whose drop delegate is this folder's (it reports itself via PhotoDropFeedback).
        for row in 0..<table.numberOfRows {
            table.scrollRowToVisible(row)
            try? await Task.sleep(for: .milliseconds(30))
            let r = table.rect(ofRow: row)
            let point = table.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            guard let dest = destination(at: point, in: window) else { continue }
            let info = FakeDraggingInfo(window: window, location: point, pasteboard: pb)
            PhotoDropFeedback.shared.update(nil, .add)
            let entered = dest.draggingEntered?(info) ?? []
            try? await Task.sleep(for: .milliseconds(30))
            let updated = dest.draggingUpdated?(info) ?? []
            try? await Task.sleep(for: .milliseconds(30))
            guard PhotoDropFeedback.shared.folderID == folder.id, !updated.isEmpty else { dest.draggingExited?(info); continue }
            let verb = PhotoDropFeedback.shared.verb
            let prepared = dest.prepareForDragOperation?(info) ?? true
            let performed = prepared && (dest.performDragOperation?(info) ?? false)
            dest.concludeDragOperation?(info)
            try? await Task.sleep(for: .milliseconds(600))
            let after = (try? model.catalog.photoCount(folderID: folder.id)) ?? -1
            let copiesAfter = (try? model.catalog.virtualCopyCount()) ?? -1
            print("DevScript vc droptest: \(modifier) on \(folderName) (row \(row), \(type(of: dest))) verb=\(verb.rawValue) "
                  + "entered=\(DragMaskProbe.maskNames(entered)) updated=\(DragMaskProbe.maskNames(updated)) performed=\(performed) "
                  + "folder \(before)→\(after) copies \(copiesBefore)→\(copiesAfter) shown=\(model.photos.count)")
            return
        }
        print("DevScript vc droptest: no row accepted the drop for \(folderName)")
    }

    private static func findOutline(_ view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let t = view as? NSOutlineView { return t }
        for sub in view.subviews { if let t = findOutline(sub) { return t } }
        return nil
    }

    /// The registered drop destination under `point` (window coordinates): SwiftUI puts a
    /// `_PlatformDraggingDestinationView` (registered for public.item) over every `.onDrop` view;
    /// they don't take part in hit testing, so pick the smallest one containing the point.
    private static func destination(at point: CGPoint, in window: NSWindow) -> (any NSDraggingDestination)? {
        guard let root = window.contentView?.superview else { return nil }
        var best: (view: NSView, area: CGFloat)?
        func visit(_ v: NSView) {
            if v.registeredDraggedTypes.contains(NSPasteboard.PasteboardType("public.item")), String(describing: type(of: v)).hasPrefix("_PlatformDragging"),
               v.convert(v.bounds, to: nil).contains(point), v.visibleRect.width > 0 {
                let area = v.bounds.width * v.bounds.height
                if best == nil || area < best!.area { best = (v, area) }
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        return best?.view
    }
}

private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let window: NSWindow
    let location: CGPoint
    let pasteboard: NSPasteboard
    init(window: NSWindow, location: CGPoint, pasteboard: NSPasteboard) {
        self.window = window; self.location = location; self.pasteboard = pasteboard
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }   // what SwiftUI's onDrag source offers (vc sourcemask)
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let s = pasteboard.string(forType: .string) else { return }
        var stop: ObjCBool = false
        block(NSDraggingItem(pasteboardWriter: s as NSString), 0, &stop)
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Logs `draggingSession(_:sourceOperationMaskFor:)` of the next drag sessions (swizzles
/// `NSView.beginDraggingSession(with:event:source:)` once; DEBUG diagnostics only).
enum DragMaskProbe {
    private static var installed = false

    static func install() {
        guard !installed else { print("DevScript vc: dragmask already installed"); return }
        installed = true
        let original = #selector(NSView.beginDraggingSession(with:event:source:))
        let probe = #selector(NSView.vcProbe_beginDraggingSession(with:event:source:))
        guard let m1 = class_getInstanceMethod(NSView.self, original), let m2 = class_getInstanceMethod(NSView.self, probe) else {
            print("DevScript vc: dragmask swizzle failed"); return
        }
        method_exchangeImplementations(m1, m2)
        print("DevScript vc: dragmask installed")
    }

    /// Calls `draggingSession(_:sourceOperationMaskFor:)` on every view of the main window that
    /// implements it (SwiftUI's drag source), with a placeholder session.
    static func querySources() {
        guard let root = ShortcutDispatcher.shared.mainWindow?.contentView?.superview else { return }
        let sel = #selector(NSDraggingSource.draggingSession(_:sourceOperationMaskFor:))
        guard let session = (NSDraggingSession.self as NSObject.Type).init() as? NSDraggingSession else { return }
        var seen = Set<String>()
        func visit(_ v: NSView) {
            if v.responds(to: sel), let source = v as? NSDraggingSource {
                let name = String(describing: type(of: v))
                if seen.insert(name).inserted {
                    let inside = source.draggingSession(session, sourceOperationMaskFor: .withinApplication)
                    let outside = source.draggingSession(session, sourceOperationMaskFor: .outsideApplication)
                    print("DevScript vc sourcemask: \(name) within=\(maskNames(inside)) outside=\(maskNames(outside))")
                }
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        if seen.isEmpty { print("DevScript vc sourcemask: no NSDraggingSource views") }
    }

    static func maskNames(_ m: NSDragOperation) -> String {
        let all: [(String, NSDragOperation)] = [("copy", .copy), ("link", .link), ("generic", .generic), ("private", .private), ("move", .move), ("delete", .delete)]
        return "\(m.rawValue) [" + all.filter { m.contains($0.1) }.map(\.0).joined(separator: ",") + "]"
    }
}

extension NSView {
    @objc fileprivate func vcProbe_beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource) -> NSDraggingSession {
        let session = vcProbe_beginDraggingSession(with: items, event: event, source: source)   // the original (swapped)
        let inside = source.draggingSession(session, sourceOperationMaskFor: .withinApplication)
        let outside = source.draggingSession(session, sourceOperationMaskFor: .outsideApplication)
        func names(_ m: NSDragOperation) -> String {
            let all: [(String, NSDragOperation)] = [("copy", .copy), ("link", .link), ("generic", .generic), ("private", .private), ("move", .move), ("delete", .delete)]
            return "\(m.rawValue) [" + all.filter { m.contains($0.1) }.map(\.0).joined(separator: ",") + "]"
        }
        print("DevScript vc dragmask: source=\(type(of: source)) within=\(names(inside)) outside=\(names(outside)) "
              + "ignoresModifiers=\(source.ignoreModifierKeys?(for: session) ?? false)")
        fflush(stdout)
        return session
    }
}
#endif
