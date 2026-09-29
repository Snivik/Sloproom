//
//  FullScreenPreview.swift
//  sloproom
//
//  F: the current photo alone on black, filling the screen (Library: focused / selected photo;
//  Develop: the photo being edited, with its live settings). A borderless window over the whole
//  screen of the main window (menu bar and Dock hidden while it is up), not the window's own
//  full-screen mode, so it opens instantly.
//
//    ← / →        previous / next photo of the current list (model.moveFocus)
//    Z / click    Fit ↔ 1:1 at the pointer (drag / scroll pans, pinch / ⌘-scroll zooms, ⌘= / ⌘-)
//    F / Esc      close
//
//  Rendering: the cached standard preview shows at once, then a render at screen resolution
//  (RenderPipeline, off-main); the neighbours in the direction of travel are pre-rendered.
//  Zoomed tiles come from its own ZoomController / RegionRenderer.
//

import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

@Observable
final class FullScreenPreview {
    static let shared = FullScreenPreview()

    private(set) var isShowing = false
    /// Photo shown and the image for it (placeholder preview until the render arrives).
    private(set) var photoID: Int64?
    private(set) var image: CGImage?
    private(set) var isPlaceholder = true
    /// Displayed (cropped) size of the photo in full-resolution pixels.
    private(set) var displayedSize: CGSize = .zero
    /// Last screen render time (ms).
    private(set) var lastRenderMS: Double = 0
    let zoom = ZoomController()

    @ObservationIgnored private(set) var window: NSWindow?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var savedPresentation: NSApplication.PresentationOptions = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var direction = 1
    /// Recent renders (photo id + edit key → image) incl. prefetched neighbours.
    @ObservationIgnored private var cache: [CacheKey: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [CacheKey] = []
    @ObservationIgnored private var sources: [Int64: RenderSource] = [:]
    @ObservationIgnored private var sourceOrder: [Int64] = []
    @ObservationIgnored private var currentSource: RenderSource?
    @ObservationIgnored private var currentSettings = EditSettings()

    private struct CacheKey: Hashable {
        let photoID: Int64
        let settings: String
        let size: CGSize
        func hash(into h: inout Hasher) { h.combine(photoID); h.combine(settings); h.combine(size.width); h.combine(size.height) }
    }

    // MARK: - Show / close

    func toggle(model: AppModel) {
        if isShowing { close() } else { show(model: model) }
    }

    func show(model: AppModel) {
        guard !isShowing else { return }
        let id = model.focusedPhotoID ?? model.photos.first(where: { model.selection.contains($0.id) })?.id
        guard let id, model.photo(id: id) != nil else { NSSound.beep(); return }
        if model.focusedPhotoID != id { model.focusedPhotoID = id }
        self.model = model
        let main = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0 !== window }
        guard let screen = main?.screen ?? NSScreen.main else { return }

        let w = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.animationBehavior = .none
        w.title = "Full Screen Preview"
        w.contentView = NSHostingView(rootView: FullScreenPreviewView(preview: self).environment(model))
        w.setFrame(screen.frame, display: false)
        window = w
        zoom.window = w
        zoom.setLevel(.fit, anchor: nil, showHUD: false)
        isShowing = true

        // Hide the menu bar and Dock (not needed when the main window is in its own full screen).
        savedPresentation = NSApp.presentationOptions
        if !(main?.styleMask.contains(.fullScreen) ?? false) {
            NSApp.presentationOptions = savedPresentation.union([.hideDock, .hideMenuBar])
        }
        w.makeKeyAndOrderFront(nil)
        installKeys()
        load(photoID: id)
    }

    func close() {
        guard isShowing else { return }
        isShowing = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSApp.presentationOptions = savedPresentation
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        zoom.purge()
        zoom.window = nil
        generation += 1
        cache.removeAll(); cacheOrder.removeAll()
        sources.removeAll(); sourceOrder.removeAll()
        currentSource = nil
        image = nil
        photoID = nil
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isShowing, let window, event.window === window else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 53: close(); return true                              // Esc
        case 123: move(by: -1); return true                        // ←
        case 124: move(by: 1); return true                         // →
        default: break
        }
        if event.charactersIgnoringModifiers?.lowercased() == "f" {
            if !event.isARepeat { close() }
            return true
        }
        return false
    }

    func move(by delta: Int) {
        guard let model else { return }
        direction = delta >= 0 ? 1 : -1
        model.moveFocus(by: delta)
        if let id = model.focusedPhotoID, id != photoID { load(photoID: id) }
    }

    /// Called when the model's focused photo changes while showing (filmstrip click, arrows).
    func focusChanged(to id: Int64?) {
        guard isShowing, let id, id != photoID else { return }
        load(photoID: id)
    }

    /// The develop session's settings changed (live edits of the shown photo).
    func refreshIfEdited() {
        guard isShowing, let photoID, let photo = model?.photo(id: photoID) else { return }
        let (settings, source) = editState(for: photo)
        if settings != currentSettings { load(photoID: photoID, keepImage: true) }
        else if currentSource == nil, let source { currentSource = source; updateZoomInputs() }
    }

    // MARK: - Rendering

    private var screenPixelSize: CGSize {
        guard let window, let screen = window.screen ?? NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        let s = screen.backingScaleFactor
        return CGSize(width: (screen.frame.width * s).rounded(), height: (screen.frame.height * s).rounded())
    }

    /// Settings + source for a photo: the develop session's live state when it shows that photo.
    private func editState(for photo: Photo) -> (EditSettings, RenderSource?) {
        if let s = model?.developSession, s.photo.id == photo.id { return (s.zoomDisplaySettings, s.source) }
        return (photo.editSettings, sources[photo.id])
    }

    private func load(photoID id: Int64, keepImage: Bool = false) {
        guard let model, let photo = model.photo(id: id) else { return }
        generation += 1
        let gen = generation
        let (settings, knownSource) = editState(for: photo)
        let size = screenPixelSize
        let key = CacheKey(photoID: id, settings: settings.jsonString() ?? "", size: size)
        if photoID != id { zoom.setInputs(nil) }
        photoID = id
        currentSettings = settings
        currentSource = knownSource
        displayedSize = GeometryMath(sourceSize: knownSource?.orientedSize ?? photo.orientedSize, geometry: settings.geometry).croppedSize
        if let hit = cache[key] {
            image = hit
            isPlaceholder = false
        } else if !keepImage || image == nil {
            image = PreviewService.shared.cachedImage(for: photo, level: .standard)
                ?? PreviewService.shared.cachedImage(for: photo, level: .thumbnail)
            isPlaceholder = true
            if image == nil {
                Task { [weak self] in
                    let preview = await PreviewService.shared.image(for: photo, level: .standard)
                    guard let self, self.generation == gen, self.image == nil else { return }
                    self.image = preview
                }
            }
        }
        updateZoomInputs()
        let catalog = model.catalog
        let needsRender = cache[key] == nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let source = knownSource ?? RenderPipeline.makeSource(url: SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog))
            var cg: CGImage?
            var ms = 0.0
            if needsRender, let source {
                let t = Date()
                cg = RenderPipeline.renderCGImage(source: source, settings: settings, targetSize: size)
                ms = Date().timeIntervalSince(t) * 1000
            }
            await self?.rendered(cg, source: source, key: key, gen: gen, ms: ms)
        }
    }

    private func rendered(_ cg: CGImage?, source: RenderSource?, key: CacheKey, gen: Int, ms: Double) {
        guard isShowing else { return }
        if let source { remember(source, for: key.photoID) }
        if let cg { store(cg, key) }
        guard gen == generation, key.photoID == photoID else { return }
        if let source {
            currentSource = source
            displayedSize = GeometryMath(sourceSize: source.orientedSize, geometry: currentSettings.geometry).croppedSize
        }
        if let cg {
            image = cg
            isPlaceholder = false
            lastRenderMS = ms
        }
        updateZoomInputs()
        prefetchNeighbour()
    }

    private func updateZoomInputs() {
        guard let photoID, let source = currentSource, let image, !isPlaceholder, displayedSize.width > 0 else { return }
        zoom.setInputs(ZoomRenderInputs(photoID: photoID, source: source, settings: currentSettings, applyCrop: true,
                                        baseRatio: CGFloat(image.width) / displayedSize.width))
    }

    /// Pre-renders the next photo in the direction of travel.
    private func prefetchNeighbour() {
        guard let model, let id = photoID, let i = model.index(of: id) else { return }
        let j = i + direction
        guard model.photos.indices.contains(j) else { return }
        let photo = model.photos[j]
        let (settings, knownSource) = editState(for: photo)
        let size = screenPixelSize
        let key = CacheKey(photoID: photo.id, settings: settings.jsonString() ?? "", size: size)
        guard cache[key] == nil else { return }
        let catalog = model.catalog
        Task.detached(priority: .utility) { [weak self] in
            let source = knownSource ?? RenderPipeline.makeSource(url: SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog))
            guard let source else { return }
            let cg = RenderPipeline.renderCGImage(source: source, settings: settings, targetSize: size)
            await self?.prefetched(cg, source: source, key: key)
        }
    }

    private func prefetched(_ cg: CGImage?, source: RenderSource, key: CacheKey) {
        guard isShowing else { return }
        remember(source, for: key.photoID)
        if let cg { store(cg, key) }
    }

    private func store(_ cg: CGImage, _ key: CacheKey) {
        cache[key] = cg
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 3 { cache[cacheOrder.removeFirst()] = nil }
    }

    private func remember(_ source: RenderSource, for id: Int64) {
        sources[id] = source
        sourceOrder.removeAll { $0 == id }
        sourceOrder.append(id)
        while sourceOrder.count > 3 { sources[sourceOrder.removeFirst()] = nil }
    }
}

/// Borderless windows can't become key by default (they need to, for keys).
private final class FullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct FullScreenPreviewView: View {
    let preview: FullScreenPreview
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let zoom = preview.zoom
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = preview.image {
                    let rect = zoom.viewport.isValid && zoom.viewport.canvasSize == geo.size
                        ? zoom.imageRect
                        : CanvasGeometry.aspectFitRect(imageSize: CGSize(width: image.width, height: image.height),
                                                       in: CGRect(origin: .zero, size: geo.size))
                    ZoomedImageLayer(image: image, imageRect: rect, zoom: zoom)
                    HandToolLayer(zoom: zoom)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ZoomHUD(zoom: zoom)
            }
            .onAppear { zoom.canvasFrame = geo.frame(in: .global) }
            .onChange(of: geo.frame(in: .global)) { _, f in zoom.canvasFrame = f }
            .onChange(of: LayoutKey(size: geo.size, displayed: preview.displayedSize, scale: displayScale), initial: true) { _, k in
                zoom.setLayout(canvasSize: k.size, displayedSize: k.displayed, displayScale: k.scale, margin: 0)
            }
        }
        .ignoresSafeArea()
        .background(.black)
        .zoomEventMonitor(zoom) { FullScreenPreview.shared.isShowing }
        .onChange(of: model.focusedPhotoID) { _, id in preview.focusChanged(to: id) }
        .onChange(of: model.developSession?.zoomDisplaySettings) { _, _ in preview.refreshIfEdited() }
    }

    private struct LayoutKey: Equatable {
        let size: CGSize
        let displayed: CGSize
        let scale: CGFloat
    }
}

extension View {
    /// F opens the full-screen preview from the main window (Library and Develop).
    func fullScreenPreviewShortcut(model: AppModel) -> some View {
        modifier(FullScreenShortcut(model: model))
    }
}

private struct FullScreenShortcut: ViewModifier {
    let model: AppModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
                    nonisolated(unsafe) let event = event
                    let handled = MainActor.assumeIsolated { Self.handle(event, model: model) }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard let window = event.window, !window.isSheet, !(window is NSPanel), window.attachedSheet == nil,
              window !== FullScreenPreview.shared.window, !FullScreenPreview.shared.isShowing,
              !TextInputGuard.isEditingText, event.charactersIgnoringModifiers?.lowercased() == "f",
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if !event.isARepeat { FullScreenPreview.shared.show(model: model) }
        return true
    }
}
