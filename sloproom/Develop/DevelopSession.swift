//
//  DevelopSession.swift
//  sloproom
//
//  State for the photo open in Develop. Owned by AppModel (`model.developSession`).
//
//  - Mutate `settings` from panels/overlays; every change schedules
//      * a debounced save to the catalog (~300 ms, bumps edit_version),
//      * a coalesced off-main re-render at the canvas' pixel size (latest settings win),
//      * an undo step (changes within ~0.6 s are grouped, so a slider drag is one undo step).
//  - `renderedImage` is what the canvas shows. `renderedWithCrop` says whether that image is
//    cropped (false while the crop tool is active: the canvas then shows the whole frame).
//
//  Interactive rendering: all renders go through `RenderPipeline.interactiveContext` (caches
//  intermediates, so the RAW demosaic is reused across slider changes). While changes stream in
//  (e.g. a slider drag) renders are PROXIES: decoded at canvas scale (cache hit) but downscaled
//  right after decode so the stages touch fewer pixels. ~150 ms after the last change a
//  full-quality render at canvas size replaces it. One render in flight; requests made meanwhile
//  collapse into one follow-up with the latest state (never a queue of stale renders).
//

import Foundation
import CoreGraphics
import CoreImage
import Observation

enum DevelopTool: String, CaseIterable, Identifiable {
    case none, crop, mask
    var id: String { rawValue }
}

@Observable
final class DevelopSession {
    let catalog: Catalog
    private(set) var photo: Photo

    /// The edit being worked on. Set freely; saving/rendering/undo are automatic.
    var settings: EditSettings {
        didSet {
            guard settings != oldValue else { return }
            if showBefore { showBefore = false }
            recordUndo(oldValue)
            scheduleSave()
            // Crop tool: the canvas shows the uncropped frame, so crop-only changes need no render.
            if !(activeTool == .crop && settings.rendersSameUncroppedFrame(as: oldValue)) { requestRender() }
        }
    }

    var activeTool: DevelopTool = .none {
        didSet {
            if (activeTool == .crop) != (oldValue == .crop) { requestRender() }
            if activeTool == .crop, oldValue != .crop { cropTool.startGeometry = settings.geometry }
        }
    }
    /// Crop tool UI state (Develop/Crop).
    let cropTool = CropToolState()
    var selectedMaskID: UUID?

    /// Before/After (backslash): show the photo with default adjustments (same crop/geometry).
    var showBefore = false {
        didSet { if showBefore != oldValue { requestRender() } }
    }
    /// White-balance eyedropper armed: the next canvas click sets WB from that point.
    var isPickingWhiteBalance = false
    /// Histogram of the image on screen (nil until the first pipeline render).
    private(set) var histogram: Histogram?

    /// Latest rendered image for the canvas (nil until the first render / placeholder).
    private(set) var renderedImage: CGImage?
    /// Whether `renderedImage` has the crop applied.
    private(set) var renderedWithCrop = true
    /// Whether `renderedImage` is only the cached preview placeholder (not a pipeline render).
    private(set) var isPlaceholder = false
    private(set) var isLoading = true
    private(set) var loadError: String?

    /// Decoded source, created off-main on open.
    private(set) var source: RenderSource?
    /// Oriented full-resolution size (from the source once loaded, else from catalog metadata).
    var orientedSize: CGSize { source?.orientedSize ?? photo.orientedSize }
    /// Camera white balance (RAW only) for initializing custom WB.
    var asShotTemperature: Double? { source?.asShotTemperature }
    var asShotTint: Double? { source?.asShotTint }

    /// Canvas size in PIXELS (points × backing scale). Set by DevelopCanvasView.
    var viewPixelSize: CGSize = .zero {
        didSet { if viewPixelSize != oldValue { requestRender() } }
    }

    // Undo
    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var isApplyingUndo = false
    private var undoGroupOpen = false
    private var undoGroupTask: Task<Void, Never>?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Save / render bookkeeping
    private var saveTask: Task<Void, Never>?
    private var hasUnsavedChanges = false
    private var renderInFlight = false
    /// Quality of the collapsed follow-up render (nil = none pending).
    private var pendingQuality: RenderQuality?
    private var lastRenderRequest = Date.distantPast
    private var finalRenderTask: Task<Void, Never>?
    /// What the current `renderedImage` shows (skip identical re-renders).
    private var renderedKey: RenderKey?

    nonisolated private enum RenderQuality: Sendable { case proxy, final }
    nonisolated private struct RenderKey: Equatable, Sendable {
        var settings: EditSettings
        var size: CGSize
        var applyCrop: Bool
        var quality: RenderQuality
    }
    private var isClosed = false
    private static let saveQueue = DispatchQueue(label: "Sloproom.DevelopSession.save", qos: .userInitiated)

    init(photo: Photo, catalog: Catalog) {
        self.photo = photo
        self.catalog = catalog
        self.settings = photo.editSettings
        load()
    }

    // MARK: - Loading

    private func load() {
        let photo = photo, catalog = catalog
        if let cached = PreviewService.shared.cachedImage(for: photo, level: .standard)
            ?? PreviewService.shared.cachedImage(for: photo, level: .thumbnail) {
            setPlaceholder(cached)
        } else {
            Task { [weak self] in
                let preview = await PreviewService.shared.image(for: photo, level: .standard)
                if let preview { self?.setPlaceholder(preview) }
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            DevelopKernels.warmUp()
            let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
            let source = RenderPipeline.makeSource(url: url)
            await self?.sourceLoaded(source)
        }
    }

    private func setPlaceholder(_ image: CGImage) {
        guard renderedImage == nil || isPlaceholder else { return }
        renderedImage = image
        renderedWithCrop = true
        isPlaceholder = true
    }

    private func sourceLoaded(_ source: RenderSource?) {
        guard !isClosed else { return }
        self.source = source
        isLoading = false
        if source == nil { loadError = "Could not open \(photo.fileName)" }
        requestRender()
    }

    // MARK: - Rendering

    /// Re-renders with the current settings. Call after anything that changes the picture.
    /// Rapid successive requests (a drag) render fast proxies; a full-quality render follows
    /// ~150 ms after the last one. At most one render runs at a time (latest state wins).
    func requestRender() {
        guard source != nil, !isClosed, viewPixelSize.width > 0, viewPixelSize.height > 0 else { return }
        let now = Date()
        let streaming = now.timeIntervalSince(lastRenderRequest) < 0.25
        lastRenderRequest = now
        finalRenderTask?.cancel()
        if streaming {
            enqueueRender(.proxy)
            finalRenderTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.enqueueRender(.final)
            }
        } else {
            enqueueRender(.final)
        }
    }

    /// Settings actually rendered (Before view = defaults with the same geometry).
    private var displaySettings: EditSettings {
        guard showBefore else { return settings }
        var before = EditSettings()
        before.geometry = settings.geometry
        return before
    }

    private func enqueueRender(_ quality: RenderQuality) {
        guard let source, !isClosed else { return }
        if renderInFlight { pendingQuality = quality; return }
        let size = viewPixelSize, applyCrop = activeTool != .crop
        // Proxy: stages run at <= ~1600 px long side (decode stays at canvas scale = cache hit).
        let proxyScale = quality == .proxy ? min(1, 1600 / max(size.width, size.height)) : 1
        let key = RenderKey(settings: displaySettings, size: size, applyCrop: applyCrop,
                            quality: proxyScale < 1 ? .proxy : .final)
        // Same picture as on screen (a final render is as good as a proxy).
        if let shown = renderedKey, shown.settings == key.settings, shown.size == key.size,
           shown.applyCrop == key.applyCrop, shown.quality == .final || key.quality == .proxy { return }
        renderInFlight = true
        pendingQuality = nil
        let settings = key.settings
        Task.detached(priority: .userInitiated) { [weak self] in
            let ctx = RenderPipeline.interactiveContext
            let image = RenderPipeline.render(source: source, settings: settings, targetSize: size,
                                              applyCrop: applyCrop, proxyScale: proxyScale, context: ctx)
            let cg = RenderPipeline.makeCGImage(image, context: ctx)
            let histogram = cg.flatMap { Histogram(image: $0) }
            await self?.renderFinished(cg, histogram: histogram, key: key)
        }
    }

    private func renderFinished(_ image: CGImage?, histogram: Histogram?, key: RenderKey) {
        renderInFlight = false
        guard !isClosed else { return }
        if let image {
            renderedImage = image
            renderedWithCrop = key.applyCrop
            isPlaceholder = false
            renderedKey = key
            if let histogram { self.histogram = histogram }
        }
        if let next = pendingQuality { enqueueRender(next) }
    }

    /// Eyedropper / Auto: sets custom white balance so `target` becomes neutral (RAW only).
    func setWhiteBalance(from target: WhiteBalanceEstimator.Target) {
        guard let source else { return }
        let current = settings
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = WhiteBalanceEstimator.estimate(source: source, settings: current, target: target)
            await self?.applyWhiteBalance(result)
        }
    }

    private func applyWhiteBalance(_ result: (temperature: Double, tint: Double)?) {
        guard let result, !isClosed else { return }
        commitUndoGroup()
        var wb = settings.whiteBalance
        wb.mode = .custom
        wb.temperature = result.temperature
        wb.tint = result.tint
        settings.whiteBalance = wb
        commitUndoGroup()
    }

    /// Overlay helper: geometry for converting view <-> image coordinates for the image
    /// currently displayed at `imageRect`.
    func canvasGeometry(imageRect: CGRect) -> CanvasGeometry {
        CanvasGeometry(imageRect: imageRect, sourceSize: orientedSize, geometry: settings.geometry,
                       showsCrop: renderedWithCrop)
    }

    // MARK: - Saving

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes pending changes immediately (called on close / photo switch).
    func saveNow() {
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        saveTask?.cancel()
        let catalog = catalog, id = photo.id, settings = settings
        Self.saveQueue.async {
            _ = try? catalog.saveEditSettings(settings, for: id)
        }
        photo.editSettingsJSON = settings.isEmpty ? nil : settings.jsonString()
        photo.editVersion += 1
    }

    /// Flushes the pending save and stops rendering. Called by AppModel when leaving the photo.
    func close() {
        saveNow()
        isClosed = true
        undoGroupTask?.cancel()
        finalRenderTask?.cancel()
        // Drop this photo's cached intermediates (decoded RAW etc.).
        RenderPipeline.interactiveContext.clearCaches()
    }

    // MARK: - Undo

    private func recordUndo(_ old: EditSettings) {
        guard !isApplyingUndo else { return }
        if !undoGroupOpen {
            undoStack.append(old)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoGroupOpen = true
        }
        undoGroupTask?.cancel()
        undoGroupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.undoGroupOpen = false
        }
    }

    /// Ends the current undo group now (e.g. at the end of a drag) so the next change is a new step.
    func commitUndoGroup() {
        undoGroupTask?.cancel()
        undoGroupOpen = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        commitUndoGroup()
        redoStack.append(settings)
        isApplyingUndo = true
        settings = previous
        isApplyingUndo = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        commitUndoGroup()
        undoStack.append(settings)
        isApplyingUndo = true
        settings = next
        isApplyingUndo = false
    }

    /// Resets every adjustment (undoable).
    func resetAll() {
        commitUndoGroup()
        settings = EditSettings()
        commitUndoGroup()
    }
}
