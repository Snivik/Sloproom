//
//  ExportDevScript.swift
//  sloproom
//
//  DEBUG-only DevScript commands for the Export sheet (`export <sub> [arg]`):
//    export sheet             open it for model.actionTargetIDs (like File > Export…)
//    export dest <folder>     use a folder as destination (no open panel; waits for the write probe)
//    export quality <n>       JPEG quality 0...100
//    export run               press Export
//    export wait              wait until the running export finished (max 5 min)
//    export cancel            press Cancel while exporting
//    export snapshot <png>    PNG of the sheet
//    export close             close the sheet (the app won't `quit` while a sheet is open)
//    export menustate         prints whether File > Export… is enabled
//    export dump              prints the controller state and the exported files
//

#if DEBUG
import AppKit
import Foundation

enum ExportDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let c = ExportController.shared
        switch parts.first ?? "" {
        case "sheet": c.present(ids: model.actionTargetIDs, model: model)
        case "dest":
            c.setDestination(URL(fileURLWithPath: rest, isDirectory: true))
            await c.probeTask?.value
            print("DevScript: export destination \(c.destination?.path ?? "nil") problem: \(c.destinationProblem ?? "none")")
        case "quality": c.quality = min(max(Int(rest) ?? 85, 0), 100)
        case "run": c.start()
        case "wait":
            for _ in 0..<3000 where c.phase == .exporting { try? await Task.sleep(for: .milliseconds(100)) }
            print("DevScript: export \(c.result?.summary ?? "not finished")")
        case "cancel": c.cancel()
        case "snapshot": snapshotSheet(to: rest)
        case "close": c.close(); c.isPresented = false
        case "menustate":
            // Like opening the menu: let SwiftUI refresh its items, then validate.
            guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else { break }
            file.delegate?.menuNeedsUpdate?(file)
            file.update()
            let item = file.items.first { $0.title == "Export…" }
            print("DevScript: File > Export… \(item == nil ? "missing" : item!.isEnabled ? "enabled" : "disabled") (targets \(model.actionTargetIDs.count)); File menu: \(file.items.map { $0.title + ($0.isEnabled ? "" : "(off)") })")
        case "dump":
            print("DevScript: export presented=\(c.isPresented) photos=\(c.photoIDs.count) phase=\(c.phase) quality=\(c.quality) dest=\(c.destination?.path ?? "nil") problem=\(c.destinationProblem ?? "none") canExport=\(c.canExport)")
            for f in c.result?.exported ?? [] {
                print(String(format: "DevScript:   %@ %dx%d %.1f MB render %.2f s encode %.2f s", f.url.path, f.pixelWidth, f.pixelHeight,
                             Double(f.bytes) / 1e6, f.renderSeconds, f.encodeSeconds))
            }
        default: print("DevScript: unknown export command \(arg)")
        }
    }

    /// PNG of the attached sheet window (like ImportDevCommands).
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
