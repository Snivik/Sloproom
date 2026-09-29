//
//  populate_catalog.swift
//  Creates/extends a catalog from a folder of photos (in place, no copying), plus a few demo
//  folders. Use with the sandboxed dev build + SLOPROOM_CATALOG_DIR inside the app container (see Tools/README.md).
//
//    Tools/harness.sh /private/tmp/claude-501/foundation-out/populate_catalog Tools/populate_catalog.swift
//    /private/tmp/claude-501/foundation-out/populate_catalog <catalog-dir> <photo-dir> [max-count]
//

import Foundation

@main
struct PopulateCatalog {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: populate_catalog <catalog-dir> <photo-dir> [max-count]")
            exit(2)
        }
        let catalog = try Catalog.open(at: URL(fileURLWithPath: args[1]))
        let dir = URL(fileURLWithPath: args[2])
        let maxCount = args.count > 3 ? Int(args[3]) ?? .max : .max

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter(PhotoMetadataReader.isSupportedImage(url:))
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let rawBases = Set(files.filter(PhotoMetadataReader.isRAW(url:)).map { $0.deletingPathExtension().path })
        let importDate = Date()
        var photos: [Photo] = []
        for url in files where photos.count < maxCount {
            let isRAW = PhotoMetadataReader.isRAW(url: url)
            let base = url.deletingPathExtension().path
            if !isRAW && rawBases.contains(base) { continue }
            guard let meta = PhotoMetadataReader.read(url: url) else { continue }
            let sidecar = isRAW ? files.first { !PhotoMetadataReader.isRAW(url: $0) && $0.deletingPathExtension().path == base }?.path : nil
            photos.append(Photo(url: url, metadata: meta, importDate: importDate, sidecarPath: sidecar))
        }
        try catalog.upsertRoot(path: dir.path, bookmark: nil, displayName: dir.lastPathComponent)
        let ids = try catalog.insertPhotos(photos)
        print("catalog \(catalog.databaseURL.path): \(try catalog.totalPhotoCount()) photos (+\(ids.count) from \(dir.path))")

        if try catalog.allFolders().isEmpty, ids.count >= 4 {
            let trips = try catalog.createFolder(name: "Trips")
            let sub = try catalog.createFolder(name: dir.lastPathComponent, parentID: trips)
            let best = try catalog.createFolder(name: "Best", parentID: sub)
            try catalog.addPhotos(ids, toFolder: sub)
            try catalog.addPhotos(ids.prefix(3), toFolder: best)
            try catalog.createFolder(name: "Portfolio")
            try catalog.setFlag(.pick, for: ids.prefix(2))
            try catalog.setFlag(.reject, for: [ids[3]])
            print("created demo folders Trips > \(dir.lastPathComponent) > Best, Portfolio")
        }
    }
}
