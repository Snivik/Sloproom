//
//  DevTools.swift
//  sloproom
//
//  Developer helper so every engineer can populate a catalog before the real importers exist:
//  File > "Add Folder in Place (Dev)…" picks a folder, registers it as a root (security-scoped
//  bookmark) and adds every photo under it WITHOUT copying. RAW+JPG pairs become one photo
//  (the RAW) with the JPG as sidecar. The import engineer may replace or remove this.
//

import AppKit
import Foundation

enum DevTools {
    static func addFolderInPlace(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder of photos to add to the catalog (files are not copied)."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let catalog = model.catalog
        do {
            try SecurityScopeManager.shared.registerRoot(url: url, in: catalog)
        } catch {
            model.report(error)
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let count = try addPhotos(under: url, catalog: catalog)
                print("DevTools: added \(count) photos from \(url.path)")
            } catch {
                await MainActor.run { model.report(error) }
            }
        }
    }

    /// Recursively adds supported images under `directory` (caller has access). Returns count.
    nonisolated static func addPhotos(under directory: URL, catalog: Catalog) throws -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var files: [URL] = []
        for case let url as URL in e where PhotoMetadataReader.isSupportedImage(url: url) { files.append(url) }

        // Pair RAW + JPG with the same base name: keep the RAW, remember the JPG as sidecar.
        let rawBases = Set(files.filter(PhotoMetadataReader.isRAW(url:)).map { $0.deletingPathExtension().path })
        var nonRawByBase: [String: String] = [:]
        for url in files where !PhotoMetadataReader.isRAW(url: url) { nonRawByBase[url.deletingPathExtension().path] = url.path }
        let importDate = Date()
        var batch: [Photo] = []
        var total = 0
        for url in files.sorted(by: { $0.path < $1.path }) {
            let base = url.deletingPathExtension().path
            let isRAW = PhotoMetadataReader.isRAW(url: url)
            if !isRAW && rawBases.contains(base) { continue }
            let sidecar = isRAW ? nonRawByBase[base] : nil
            guard let meta = PhotoMetadataReader.read(url: url, sidecar: sidecar.map(URL.init(fileURLWithPath:))) else { continue }
            batch.append(Photo(url: url, metadata: meta, importDate: importDate, sidecarPath: sidecar))
            if batch.count >= 100 {
                try catalog.insertPhotos(batch)
                total += batch.count
                batch.removeAll()
            }
        }
        try catalog.insertPhotos(batch)
        return total + batch.count
    }
}

// MARK: - Dev script (headless UI verification)

#if DEBUG
/// Runs a tiny UI script from the `SLOPROOM_DEV_SCRIPT` environment variable so the app can be
/// verified without screen-recording / accessibility permissions. Commands separated by ";":
///   wait <seconds> | snapshot <png path> | mode library|develop | select <index>
///   source all|last|<folder name> | flag pick|none|reject | exposure <ev> | tool none|crop|mask | quit
///   import… (see Import/ImportDevCommands.swift)
///   straighten <deg> | aspect <w>:<h>|original|custom|preset <name> | rotate left|right | crop commit|cancel|swap
/// Example:
///   SLOPROOM_CATALOG_DIR=/tmp/cat SLOPROOM_DEV_SCRIPT="wait 3; snapshot /tmp/a.png; quit" sloproom.app/Contents/MacOS/sloproom
enum DevScript {
    static func runIfRequested(model: AppModel) {
        guard let script = ProcessInfo.processInfo.environment["SLOPROOM_DEV_SCRIPT"], !script.isEmpty else { return }
        let commands = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            for command in commands { await execute(command, model: model) }
        }
    }

    /// Live debugging: with SLOPROOM_DEV_LISTEN=<file>, the app polls that file and runs any
    /// commands written to it (one per line or ";"-separated), then empties it. Output goes to stdout.
    static func listenIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["SLOPROOM_DEV_LISTEN"], !path.isEmpty else { return }
        FileManager.default.createFile(atPath: path, contents: Data())
        print("DevScript: listening on \(path)")
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try? Data().write(to: URL(fileURLWithPath: path))
                let commands = text.split(whereSeparator: { $0 == ";" || $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for command in commands { await execute(command, model: model) }
                print("DevScript: done")
                fflush(stdout)
            }
        }
    }

    static func execute(_ command: String, model: AppModel) async {
        do {
                let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                print("DevScript: \(command)")
                switch parts[0] {
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "snapshot": snapshot(to: arg)
                case "mode": model.mode = arg == "develop" ? .develop : .library
                case "select":
                    if let i = Int(arg), model.photos.indices.contains(i) { model.click(photoID: model.photos[i].id, command: false, shift: false) }
                case "source":
                    switch arg {
                    case "all": model.selectedSource = .all
                    case "last": model.selectedSource = .lastImport
                    default:
                        if let f = model.folders.first(where: { $0.name == arg }) {
                            model.selectedSource = .folder(id: f.id, includeSubfolders: model.includeSubfolders)
                        }
                    }
                case "flag": model.setFlag(arg == "pick" ? .pick : arg == "reject" ? .reject : .none)
                case "exposure": model.developSession?.settings.tone.exposure = Double(arg) ?? 0
                case "tool": model.developSession?.activeTool = DevelopTool(rawValue: arg) ?? .none
                case "lightroom": LightroomImportDev.handle(arg, model: model)   // see LightroomImportDev.swift
                case "straighten": model.developSession?.setStraighten(Double(arg) ?? 0)
                case "aspect": // "aspect 4:5" | "aspect original"
                    let wh = arg.split(separator: ":").compactMap { Double($0) }
                    if arg == "original" { model.developSession?.selectCropAspect(.original) }
                    else if arg == "custom" { model.developSession?.selectCropAspect(.custom) }
                    else if arg.hasPrefix("preset "), let s = model.developSession {   // "aspect preset Vertical 4:5"
                        let name = String(arg.dropFirst("preset ".count))
                        if let p = s.cropTool.presets.first(where: { $0.name == name }) { s.selectCropAspect(.preset(p.id)) }
                        else { print("DevScript: no crop preset \(name) in \(s.cropTool.presets.map(\.name))") }
                    }
                    else if wh.count == 2 { model.developSession?.applyCropAspect(wh[0] / wh[1], presetID: nil) }
                case "rotate": model.developSession?.rotateQuarter(clockwise: arg != "left")
                case "crop": // "crop commit" | "crop cancel" | "crop swap"
                    switch arg {
                    case "commit": model.developSession?.commitCrop()
                    case "cancel": model.developSession?.cancelCrop()
                    default: model.developSession?.swapCropOrientation()
                    }
                case "adjust": DevelopDevScript.adjust(model.developSession, arg)   // e.g. "adjust shadows 50"
                case "before": model.developSession?.showBefore = arg == "on"
                case "window": DevelopDevScript.resizeWindow(arg)   // "window 1400 2200" (points)
                case "scroll": DevelopDevScript.scrollInspector(Double(arg) ?? 0)   // 0 = top ... 1 = bottom
                case "quit": NSApp.terminate(nil)
                case let c where c.hasPrefix("import"): ImportDevCommands.run(c, arg: arg, model: model)
                case "export": await ExportDevScript.run(arg, model: model)   // see Export/UI/ExportDevScript.swift
                case let c where IntegrationDevScript.commands.contains(c): IntegrationDevScript.run(c, arg, model: model)
                case let c where StripDevScript.commands.contains(c): StripDevScript.run(c, arg, model: model)   // Library/Flags/StripDevScript.swift
                case let c where MaskDevScript.commands.contains(c): MaskDevScript.run(c, arg, session: model.developSession)
                case let c where ZoomDevScript.commands.contains(c): await ZoomDevScript.run(c, arg, model: model)   // Develop/Zoom
                case "key", "type", "click", "dclick", "dump", "menus", "action", "row", "whichmenu": FoldersDevScript.run(parts[0], arg, model: model)
                default: print("DevScript: unknown command \(command)")
                }
        }
    }

    /// Writes a PNG of the app's main window. Uses CGWindowListCreateImage (looked up at runtime;
    /// it is obsoleted in the SDK), which can capture the app's OWN windows without
    /// screen-recording permission.
    static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else {
            print("DevScript: no window to snapshot")
            return
        }
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            print("DevScript: CGWindowListCreateImage unavailable")
            return
        }
        let capture = unsafeBitCast(sym, to: CaptureFn.self)
        // .null rect = window bounds; 1<<3 = kCGWindowListOptionIncludingWindow; 1<<0 = boundsIgnoreFraming
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
            print("DevScript: capture failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("DevScript: wrote \(path) (\(image.width)x\(image.height))")
        }
    }
}

#endif
