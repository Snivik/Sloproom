//
//  ImportThumbnails.swift
//  sloproom
//
//  Small (256 px) embedded-preview thumbnails of not-yet-imported files for the import grid.
//  Lazy (only visible cells ask), bounded concurrency (cards are slow), cancellable, memory-cached.
//

import Foundation
import CoreGraphics
import SwiftUI

nonisolated final class ImportThumbnailLoader: @unchecked Sendable {
    static let shared = ImportThumbnailLoader()
    static let maxPixelSize = 256

    private let cache = NSCache<NSString, CGImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Sloproom.ImportThumbnails"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    init() { cache.countLimit = 3000 }

    func cached(_ url: URL) -> CGImage? { cache.object(forKey: url.path as NSString) }

    func image(for url: URL) async -> CGImage? {
        if let hit = cached(url) { return hit }
        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box()
        let op = BlockOperation { [self] in
            if let image = PreviewService.embeddedThumbnail(url: url, maxPixelSize: Self.maxPixelSize) {
                cache.setObject(image, forKey: url.path as NSString)
                box.image = image
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                // Runs after the block, or right away when the op was cancelled before it started.
                op.completionBlock = { cont.resume(returning: box.image) }
                queue.addOperation(op)
            }
        } onCancel: {
            op.cancel()
        }
    }
}

/// Aspect-fit thumbnail of a file in the import source.
struct ImportThumbnailView: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            if let hit = ImportThumbnailLoader.shared.cached(url) { image = hit; return }
            image = nil
            if let loaded = await ImportThumbnailLoader.shared.image(for: url), !Task.isCancelled { image = loaded }
        }
    }
}
