//
//  LightroomImportDev.swift
//  sloproom
//
//  DevScript support for the Lightroom import sheet (DEBUG only):
//    lightroom preview <catalog.lrcat>   open the sheet and load the catalog (no open panel)
//    lightroom import <catalog.lrcat>    same, then start the import immediately
//    lightroom snapshot <png>            capture the sheet window
//  The .lrcat must be readable by the sandboxed app (i.e. inside the app container).
//

#if DEBUG
import AppKit
import CoreGraphics
import Foundation

enum LightroomImportDev {
    struct Request {
        var url: URL
        var autoImport: Bool
    }

    private static var pending: Request?

    static func takePendingRequest() -> Request? {
        defer { pending = nil }
        return pending
    }

    static func handle(_ arg: String, model: AppModel) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch command {
        case "preview", "import":
            pending = Request(url: URL(fileURLWithPath: value), autoImport: command == "import")
            model.presentedSheet = .importLightroom
        case "snapshot":
            snapshotSheet(to: value)
        default:
            print("DevScript: unknown lightroom command \(arg)")
        }
    }

    /// Captures the attached sheet (sheets are separate windows, so `snapshot` misses them).
    private static func snapshotSheet(to path: String) {
        guard let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first else {
            print("DevScript: no sheet to snapshot")
            return
        }
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: CaptureFn.self)
        guard let image = capture(.null, 1 << 3, UInt32(sheet.windowNumber), 1 << 0)?.takeRetainedValue() else {
            print("DevScript: sheet capture failed")
            return
        }
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("DevScript: wrote \(path) (\(image.width)x\(image.height))")
        }
    }
}
#endif
