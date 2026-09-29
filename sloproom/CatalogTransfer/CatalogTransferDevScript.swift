//
//  CatalogTransferDevScript.swift
//  sloproom
//
//  DEBUG-only DevScript commands (`catalog <sub> [arg]`), no panels:
//    catalog export <file>          Export Catalog to <file> (waits; leaves the result sheet open)
//    catalog inspect <file>         Import Catalog… with <file>: validate + summary sheet
//    catalog replace                press "Replace Current Catalog" (waits until done)
//    catalog close                  Cancel / Done / OK on the sheet
//    catalog snapshot <png>         PNG of the sheet
//    catalog dump                   counts of the open catalog (photos, flags, edits, folders, memberships, roots) + sheet step
//    catalog roots                  roots with status
//    catalog relink <old root path> => <new folder>   sample check + relink (no warning prompt)
//    catalog menustate              File menu items
//

#if DEBUG
import AppKit
import Foundation

enum CatalogTransferDevScript {
    /// Bookmarks of roots relinked away, reused when relinking back (no open panel grants access here).
    nonisolated(unsafe) private static var stashedBookmarks: [String: Data] = [:]

    static func run(_ arg: String, model: AppModel) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let c = CatalogTransferController.shared
        switch parts.first ?? "" {
        case "export":
            await c.export(to: URL(fileURLWithPath: rest), model: model)
            print("DevScript: catalog export → \(stepText(c.step))")
        case "inspect":
            await c.inspect(URL(fileURLWithPath: rest), model: model)
            print("DevScript: catalog inspect → \(stepText(c.step))")
        case "replace":
            await c.replace(model: model)
            print("DevScript: catalog replace → \(stepText(c.step))")
        case "close": c.dismiss()
        case "snapshot": snapshotSheet(to: rest)
        case "dump": dump(model)
        case "roots":
            let mounted = RootAccess.mountedVolumePaths()
            for r in (try? model.catalog.allRoots()) ?? [] {
                print("DevScript: root \(r.id) \(r.path) [\(r.displayName ?? "-")] \(RootAccess.status(of: r, mounted: mounted).title)")
            }
        case "relink":
            let pieces = rest.components(separatedBy: " => ")
            guard pieces.count == 2, let root = try? model.catalog.allRoots().first(where: { $0.path == Catalog.normalizedPath(pieces[0]) }) else {
                print("DevScript: catalog relink <old root path> => <new folder>; no such root"); return
            }
            let url = URL(fileURLWithPath: pieces[1], isDirectory: true)
            do {
                let check = try model.catalog.relinkCheck(root: root, newPath: url.path)
                print("DevScript: relink check \(check.found)/\(check.sampled) found (looksRight=\(check.looksRight)) missing e.g. \(check.missingExamples.first ?? "-")")
                let t = Date()
                if let b = root.bookmark { stashedBookmarks[root.path] = b }
                let bookmark = (try? SecurityScope.makeBookmark(for: url)) ?? stashedBookmarks[Catalog.normalizedPath(url.path)]
                let result = try await RootsAccessView.relink(root, to: url, bookmark: bookmark, model: model)
                print(String(format: "DevScript: relinked %d photos (%d sidecars) %@ → %@ in %.2f s", result.photoIDs.count,
                             result.sidecarsRewritten, result.oldPath, result.newPath, Date().timeIntervalSince(t)))
            } catch {
                print("DevScript: relink failed: \(error)")
            }
        case "menustate":
            guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else { break }
            file.update()
            print("DevScript: File menu: \(file.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : "(off)") })")
        default: print("DevScript: unknown catalog command \(arg)")
        }
    }

    private static func dump(_ model: AppModel) {
        let db = model.catalog.db
        func n(_ sql: String) -> Int64 { (try? db.scalarInt(sql)) ?? -1 }
        let editsHash = ((try? db.query("SELECT id, edit_settings, edit_version FROM photos WHERE edit_settings IS NOT NULL ORDER BY id") {
            "\($0.int(0)):\($0.string(1)):\($0.int(2))"
        }) ?? []).joined(separator: "|")
        print("DevScript: catalog dir=\(model.catalog.catalogDirectory.path) photos=\(n("SELECT COUNT(*) FROM photos")) "
              + "picked=\(n("SELECT COUNT(*) FROM photos WHERE flag = 1")) rejected=\(n("SELECT COUNT(*) FROM photos WHERE flag = -1")) "
              + "rated=\(n("SELECT COUNT(*) FROM photos WHERE rating > 0")) edited=\(n("SELECT COUNT(*) FROM photos WHERE edit_settings IS NOT NULL")) "
              + "editsDigest=\(editsHash.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }) "
              + "folders=\(n("SELECT COUNT(*) FROM folders")) memberships=\(n("SELECT COUNT(*) FROM folder_photos")) roots=\(n("SELECT COUNT(*) FROM roots"))")
        print("DevScript: model photos=\(model.photos.count) total=\(model.totalPhotoCount) folders=\(model.folders.count) source=\(model.selectedSource) mode=\(model.mode) "
              + "develop=\(model.developSession != nil) selection=\(model.selection.count) step=\(stepText(CatalogTransferController.shared.step))")
        let backups = CatalogTransfer.backups(in: CatalogTransfer.backupsDirectory(for: model.catalog))
        print("DevScript: backups \(backups.map(\.lastPathComponent))")
        let previews = model.catalog.catalogDirectory.appendingPathComponent("Previews")
        let shards = (try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? []
        let files = shards.reduce(0) { $0 + ((try? FileManager.default.contentsOfDirectory(atPath: previews.appendingPathComponent($1).path))?.count ?? 0) }
        print("DevScript: previews on disk: \(files) files")
    }

    private static func stepText(_ step: CatalogTransferController.Step?) -> String {
        switch step {
        case nil: "none"
        case .working(let t)?: "working(\(t))"
        case .exported(let r)?: "exported(\(r.url.lastPathComponent), \(r.info.photoCount) photos, \(r.bytes) bytes, \(String(format: "%.2f", r.seconds)) s, \(r.writeMethod))"
        case .summary(let s)?: "summary(\(s.candidate.info.photoCount) photos, \(s.candidate.info.folderCount) folders, roots \(s.roots.map { "\($0.root.path): \($0.status.title)" }))"
        case .imported(let o)?: "imported(\(o.info.photoCount) photos, backup \(o.backup.lastPathComponent), needsAttention \(o.needsAttention), \(String(format: "%.2f", o.seconds)) s)"
        case .failed(let title, let message)?: "failed(\(title): \(message))"
        }
    }

    private static func snapshotSheet(to path: String) {
        guard let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first else {
            print("DevScript: no sheet to snapshot")
            return
        }
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let image = unsafeBitCast(sym, to: CaptureFn.self)(.null, 1 << 3, UInt32(sheet.windowNumber), 1 << 0)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("DevScript: sheet capture failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("DevScript: wrote \(path) (\(image.width)x\(image.height))")
    }
}
#endif
