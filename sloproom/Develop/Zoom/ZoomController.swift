//
//  ZoomController.swift
//  sloproom
//
//  Zoom / pan state of one image canvas (the Develop canvas: `ZoomController.develop`, the
//  full-screen preview: its own instance) plus the sharp "refine" tile.
//
//  - `viewport` (CanvasViewport) = level + pan center + layout; `imageRect` is where the whole
//    displayed image is drawn and is what overlays receive (CanvasGeometry stays exact).
//  - While zooming / panning the canvas shows the fit render scaled up immediately; ~100 ms after
//    the view stops changing, `RegionRenderer` renders the visible region (plus a small margin)
//    at the needed scale and `tile` is drawn over it. Settings changes re-render the tile right
//    away (one render in flight, latest wins); the old tile stays up meanwhile unless the
//    geometry changed.
//  - Zoom is locked to Fit while `isLocked` (crop tool).
//  - Trackpad pinch (`magnify(by:anchor:phase:)`) is free-form (Fit … 800 %), anchored at the
//    pointer. Each event only moves `viewport` (the canvas transforms the images it already has);
//    the region render waits until the fingers pause for 150 ms or lift (then at once), and the
//    old tile stays up, scaled, until the sharp one replaces it. Two-finger double tap
//    (`smartMagnify(at:)`) toggles Fit ↔ 100 % at the pointer.
//

import AppKit
import CoreGraphics
import Foundation
import Observation

/// What the canvas needs rendered (set by the canvas whenever the picture changes).
struct ZoomRenderInputs {
    let photoID: Int64
    let source: RenderSource
    let settings: EditSettings
    let applyCrop: Bool
    /// Device pixels per displayed-image pixel of the base (fit) image on screen.
    let baseRatio: CGFloat
}

@Observable
final class ZoomController {
    /// The Develop canvas' zoom (kept across photos, like Lightroom).
    static let develop = ZoomController()

    struct Tile {
        let image: CGImage
        let normalizedRect: CGRect
        let photoID: Int64
        let settings: EditSettings
        let applyCrop: Bool
        let scale: CGFloat
    }

    private(set) var viewport = CanvasViewport(canvasSize: .zero, displayedSize: .zero)
    /// Level Z / click toggles to from Fit (the last level picked in the zoom control).
    var zoomInLevel: ZoomLevel = .ratio(1)
    /// Crop tool: zoom stays at Fit.
    var isLocked = false {
        didSet { if isLocked, viewport.level != .fit { setLevel(.fit, anchor: nil, showHUD: false) } }
    }
    /// Space bar held: temporary hand tool over any tool.
    var spaceHeld = false
    /// A hand drag is in progress (closed-hand cursor).
    var isPanning = false
    private(set) var tile: Tile?
    /// Transient "100%" badge.
    private(set) var hudText: String?
    /// Last region render (ms) and whether it used the cached decode (DevScript / report).
    private(set) var lastRefineMS: Double = 0
    private(set) var lastRefineCached = false
    private(set) var refineCount = 0

    /// Canvas frame in window coordinates (SwiftUI global, top-left origin) for mapping events.
    @ObservationIgnored var canvasFrame: CGRect = .zero
    @ObservationIgnored weak var window: NSWindow?

    @ObservationIgnored private var inputs: ZoomRenderInputs?
    @ObservationIgnored private let renderer = RegionRenderer()
    @ObservationIgnored private(set) var inFlight = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// A trackpad pinch is in progress (between its began and ended events).
    @ObservationIgnored private(set) var gestureActive = false
    /// Displayed-normalized image point that was under the fingers when the pinch began (kept under them).
    @ObservationIgnored private var gesturePoint: CGPoint?
    /// When the last pinch ended (until its sharp render is up), for `stats.sharpAfterEndMS`.
    @ObservationIgnored private var gestureEndedAt: Date?
    /// Pinch timing (DevScript `zoomstats`): per-event handling, per-frame cost, sharp render after lift.
    struct GestureStats {
        var events = 0
        var handlerMSTotal = 0.0, handlerMSMax = 0.0
        var frames = 0
        var frameMSTotal = 0.0, frameMSMax = 0.0
        var sharpAfterEndMS: Double?
        var sharpRendered = false
    }
    @ObservationIgnored var stats = GestureStats()

    var level: ZoomLevel { viewport.level }
    var imageRect: CGRect { viewport.imageRect }
    var isZoomed: Bool { viewport.isZoomed }

    // MARK: - Layout (set by the canvas)

    func setLayout(canvasSize: CGSize, displayedSize: CGSize, displayScale: CGFloat, margin: CGFloat = 16) {
        var v = viewport
        v.canvasSize = canvasSize
        v.displayedSize = displayedSize
        v.displayScale = displayScale
        v.margin = margin
        guard v != viewport else { return }
        v.center = v.clampedCenter
        viewport = v
        scheduleRefine(delay: 100)
    }

    /// The picture changed (settings, source, tool, base render).
    func setInputs(_ new: ZoomRenderInputs?) {
        let photoChanged = new?.photoID != inputs?.photoID || new.map { ObjectIdentifier($0.source) } != inputs.map { ObjectIdentifier($0.source) }
        inputs = new
        if photoChanged {
            generation += 1
            tile = nil
            renderer.purge()
        }
        scheduleRefine(delay: 0)
    }

    /// Photo closed / preview dismissed: drop tiles and cached decodes.
    func purge() {
        generation += 1
        inputs = nil
        tile = nil
        refineTask?.cancel()
        renderer.purge()
    }

    // MARK: - Actions

    func setLevel(_ level: ZoomLevel, anchor: CGPoint?, remember: Bool = false, showHUD: Bool = true) {
        guard !isLocked || level == .fit else { return }
        if remember, level != .fit { zoomInLevel = level }
        viewport = viewport.zoomed(to: level, anchor: anchor)
        if showHUD { flashHUD() }
        scheduleRefine(delay: 100)
    }

    /// Sets `level` with displayed-normalized point `center` at the view center (DevScript, navigator).
    func setLevel(_ level: ZoomLevel, centeredOn center: CGPoint) {
        guard !isLocked || level == .fit else { return }
        var v = viewport
        v.level = level
        v.center = center
        v.center = v.clampedCenter
        viewport = v
        scheduleRefine(delay: 100)
    }

    /// Z / click: Fit ↔ `zoomInLevel` around `anchor` (view point; nil = center).
    func toggle(at anchor: CGPoint?) {
        if isZoomed { setLevel(.fit, anchor: anchor) } else { setLevel(zoomInLevel, anchor: anchor) }
    }

    /// ⌘= / ⌘-.
    func step(zoomIn: Bool, anchor: CGPoint?) {
        setLevel(viewport.stepped(in: zoomIn), anchor: anchor)
    }

    func pan(by delta: CGSize) {
        guard isZoomed else { return }
        let v = viewport.panned(by: delta)
        guard v != viewport else { return }
        viewport = v
        scheduleRefine(delay: 100)
    }

    /// Phase of a magnify event (`.none` = a discrete step, e.g. ⌘-scroll).
    enum GesturePhase { case none, began, changed, ended }

    /// Pinch / ⌘-scroll: free-form zoom by `factor` keeping the image point under `anchor`
    /// fixed. During a pinch the sharp re-render waits for a 150 ms pause; at the end it starts at once.
    func magnify(by factor: CGFloat, anchor: CGPoint?, phase: GesturePhase = .none) {
        guard !isLocked else { gestureActive = false; return }
        if phase == .began {
            gestureActive = true
            gestureEndedAt = nil
            gesturePoint = anchor.map { viewport.displayedPoint(fromView: $0) }
        }
        if factor > 0, factor != 1, factor.isFinite {
            let v = viewport.magnified(by: factor, anchor: anchor, holding: phase == .none ? nil : gesturePoint)
            if v != viewport {
                viewport = v
                flashHUD()
            }
        }
        if phase == .ended {
            gestureActive = false
            gesturePoint = nil
            gestureEndedAt = Date()
            stats.sharpAfterEndMS = nil
            scheduleRefine(delay: 0)
        } else {
            scheduleRefine(delay: phase == .none ? 100 : 150)
        }
    }

    /// Two-finger double tap (smart magnify): Fit ↔ 100 % around `anchor`, like Preview / Lightroom.
    func smartMagnify(at anchor: CGPoint?) {
        guard !isLocked else { return }
        setLevel(isZoomed ? .fit : .ratio(1), anchor: anchor)
    }

    /// ⌘0.
    func zoomToFit() {
        setLevel(.fit, anchor: nil)
    }

    /// Current zoom for display: "Fit (23%)", "100%".
    var displayLabel: String {
        viewport.level == .fit || viewport.level == .fill
            ? "\(CanvasViewport.label(viewport.level)) \(viewport.percentLabel)" : viewport.percentLabel
    }

    private func flashHUD() {
        hudText = viewport.level == .fit ? "Fit" : viewport.percentLabel
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.hudText = nil
        }
    }

    // MARK: - Event mapping

    /// Canvas point (top-left origin) of a window location (AppKit base coordinates).
    func canvasPoint(fromWindow p: NSPoint, in window: NSWindow) -> CGPoint? {
        guard let content = window.contentView else { return nil }
        let q = content.convert(p, from: nil)
        let y = content.isFlipped ? q.y : content.bounds.height - q.y
        return CGPoint(x: q.x - canvasFrame.minX, y: y - canvasFrame.minY)
    }

    #if DEBUG
    /// DevScript: pretend the pointer is here (canvas coordinates) instead of moving the real cursor.
    @ObservationIgnored var debugMouseLocation: CGPoint?
    #endif

    /// Mouse position over the canvas (nil when outside).
    var mouseLocation: CGPoint? {
        #if DEBUG
        if let debugMouseLocation { return debugMouseLocation }
        #endif
        guard let window, let p = canvasPoint(fromWindow: window.mouseLocationOutsideOfEventStream, in: window) else { return nil }
        return CGRect(origin: .zero, size: canvasFrame.size).contains(p) ? p : nil
    }

    // MARK: - Tile

    /// The tile to draw now (nil if none fits the current picture).
    var visibleTile: Tile? {
        guard let tile, let inputs, isZoomed, tile.photoID == inputs.photoID, tile.applyCrop == inputs.applyCrop,
              tile.settings.geometry == inputs.settings.geometry,
              viewport.pixelRatio > inputs.baseRatio * 1.05 else { return nil }
        return tile
    }

    private func scheduleRefine(delay: Int) {
        refineTask?.cancel()
        refineTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
            }
            self?.refine()
        }
    }

    private func refine() {
        guard let inputs, isZoomed, !isLocked, viewport.pixelRatio > inputs.baseRatio * 1.05 else {
            sharpAfterGesture(rendered: false)   // the base render is already sharp at this zoom
            return
        }
        let scale = min(1, viewport.pixelRatio)
        let visible = viewport.visibleDisplayedRect
        guard visible.width > 0, visible.height > 0 else { return }
        // Margin of ~96 device px around the view so small pans stay sharp.
        let d = viewport.displayedSize
        let mx = 96 / max(d.width * viewport.pixelRatio, 1), my = 96 / max(d.height * viewport.pixelRatio, 1)
        let region = visible.insetBy(dx: -mx, dy: -my).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if let tile, tile.photoID == inputs.photoID, tile.settings == inputs.settings, tile.applyCrop == inputs.applyCrop,
           abs(tile.scale - scale) < 0.001, tile.normalizedRect.insetBy(dx: -1e-6, dy: -1e-6).contains(visible) {
            sharpAfterGesture(rendered: false)   // the current tile still covers the view
            return
        }
        if inFlight { pending = true; return }
        inFlight = true
        pending = false
        let gen = generation, renderer = renderer
        let photoID = inputs.photoID, source = inputs.source, settings = inputs.settings, applyCrop = inputs.applyCrop
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = renderer.render(source: source, settings: settings, applyCrop: applyCrop, scale: scale, region: region)
            await self?.refineFinished(result, gen: gen, photoID: photoID, settings: settings, applyCrop: applyCrop, scale: scale)
        }
    }

    private func refineFinished(_ result: RegionRenderer.Result?, gen: Int, photoID: Int64, settings: EditSettings,
                                applyCrop: Bool, scale: CGFloat) {
        inFlight = false
        if gen == generation, let result {
            tile = Tile(image: result.image, normalizedRect: result.normalizedRect, photoID: photoID,
                        settings: settings, applyCrop: applyCrop, scale: scale)
            lastRefineMS = result.milliseconds
            lastRefineCached = result.usedCachedDecode
            refineCount += 1
            if !pending { sharpAfterGesture(rendered: true) }
        }
        if pending { pending = false; refine() }
    }

    /// Records the time from the end of a pinch to the sharp picture.
    private func sharpAfterGesture(rendered: Bool) {
        guard let end = gestureEndedAt, !gestureActive else { return }
        gestureEndedAt = nil
        stats.sharpAfterEndMS = Date().timeIntervalSince(end) * 1000
        stats.sharpRendered = rendered
    }
}
