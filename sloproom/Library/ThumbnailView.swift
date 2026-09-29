//
//  ThumbnailView.swift
//  sloproom
//

import SwiftUI

/// The one place that loads a preview image for display (grid + filmstrip).
/// - memory hits render on the first frame (no placeholder flash while scrolling),
/// - loads are cancelled when the view disappears (`.task(id:)`),
/// - keeps the previous image while a new version loads after an edit, and waits for edits to
///   settle (1 s) before re-rendering,
/// - missing originals show an "offline" badge instead of a blank cell (or over an older preview).
struct ThumbnailView: View {
    let photo: Photo
    var level: PreviewLevel = .thumbnail

    @State private var image: CGImage?
    @State private var loadedKey: LoadKey?
    @State private var status: Status = .loading

    private enum Status { case loading, loaded, offline, failed }

    private struct LoadKey: Hashable {
        let id: Int64
        let editVersion: Int
        let level: PreviewLevel
        let revision: Int
    }

    var body: some View {
        let key = LoadKey(id: photo.id, editVersion: photo.editVersion, level: level,
                          revision: PreviewJobs.shared.revision(for: photo.id))
        let shown = loadedKey == key ? image : (PreviewService.shared.cachedImage(for: photo, level: level) ?? image)
        ZStack {
            if let shown {
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                if status == .failed || status == .offline {
                    Image(systemName: status == .offline ? "externaldrive.badge.xmark" : "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .help(status == .offline ? "Original file is offline (connect the drive)" : "The preview could not be loaded")
                        .accessibilityLabel(status == .offline ? "Offline" : "Preview failed")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if status == .offline { offlineBadge }
        }
        .task(id: key) { await load(key) }
    }

    private var offlineBadge: some View {
        Label("Offline", systemImage: "externaldrive.badge.xmark")
            .labelStyle(.iconOnly)
            .font(.caption2)
            .padding(3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
            .padding(4)
            .help("Original file is offline")
    }

    private func load(_ key: LoadKey) async {
        let service = PreviewService.shared
        if let cached = service.cachedImage(for: photo, level: level) {
            image = cached
            status = .loaded
            loadedKey = key
            return
        }
        // Edits arrive in bursts (slider drags save every few hundred ms): keep showing the old
        // image and only re-render once they settle. Cancelled by the next edit.
        if image != nil, let old = loadedKey, old.id == key.id, old.editVersion != key.editVersion {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        let result = await service.load(photo, level: level, priority: .visible)
        if Task.isCancelled { return }
        if let loaded = result.image { image = loaded }
        status = result.isOffline ? .offline : (result.image == nil && image == nil ? .failed : .loaded)
        loadedKey = key
    }
}
