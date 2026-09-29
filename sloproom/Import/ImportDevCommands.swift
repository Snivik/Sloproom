//
//  ImportDevCommands.swift
//  sloproom
//
//  DEBUG-only DevScript commands to drive the import sheet headlessly (paths inside the container):
//    importsheet                     open File > Import Photos…
//    importsource <folder>           scan a folder (no open panel)
//    importdest <folder>             use a folder as copy destination (registers a root)
//    importmode copy|inplace         import mode
//    importfolder <name>             "New folder" name
//    importrun                       press Import (then the sheet closes and the library shows the photos)
//    importsnapshot <png>            PNG of the import sheet
//    importclose                     close the sheet (the app won't `quit` while a sheet is open)
//

#if DEBUG
import AppKit
import Foundation

enum ImportDevCommands {
    private static weak var session: ImportSession?
    private static var start: (() -> Void)?

    static func attach(_ session: ImportSession, start: @escaping () -> Void) {
        self.session = session
        self.start = start
    }

    static func run(_ command: String, arg: String, model: AppModel) {
        switch command {
        case "importsheet": model.presentedSheet = .importPhotos
        case "importsource": session?.open(folder: URL(fileURLWithPath: arg, isDirectory: true))
        case "importdest":
            do { try session?.setDestination(folder: URL(fileURLWithPath: arg, isDirectory: true)) } catch { print("DevScript: \(error)") }
        case "importmode": session?.mode = arg == "inplace" ? .addInPlace : .copy
        case "importfolder": session?.newFolderName = arg
        case "importrun": start?()
        case "importsnapshot": snapshotSheet(to: arg)
        case "importclose": model.presentedSheet = nil
        default: print("DevScript: unknown import command \(command)")
        }
    }

    /// Like DevScript.snapshot, but of the attached sheet window.
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
