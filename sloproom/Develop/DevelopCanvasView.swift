//
//  DevelopCanvasView.swift
//  sloproom
//
//  Shows `session.renderedImage` (Fit by default, zoomable) and hosts the tool overlay.
//
//  Overlay contract: overlays are laid out over the WHOLE canvas (same coordinate space as
//  this view, top-left origin) and receive `imageRect` = where the WHOLE displayed image is
//  drawn in that space — when zoomed it is larger than the canvas and may start at negative
//  coordinates. Convert with `session.canvasGeometry(imageRect:)` (see CanvasGeometry), which
//  therefore stays exact at any zoom / pan. While the crop tool is active the displayed image
//  is the UNCROPPED frame and zoom is locked to Fit.
//
//  Zoom (Develop/Zoom): `ZoomController.develop` holds level + pan; the fit render is shown
//  scaled immediately and a sharp region tile follows. Layers, bottom to top: image + tile,
//  hand tool (no tool active: click = zoom, drag = pan), tool overlay, WB eyedropper,
//  space-bar hand (over everything but crop), navigator, zoom badge.
//

import AppKit
import SwiftUI

struct DevelopCanvasView: View {
    let session: DevelopSession
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    private let margin: CGFloat = 16
    private var zoom: ZoomController { ZoomController.develop }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: margin, dy: margin)
            let displayed = session.canvasGeometry(imageRect: .zero).displayedImageSize
            ZStack(alignment: .topLeading) {
                Color(white: 0.12)
                if let image = session.renderedImage {
                    let rect = imageRect(for: image, bounds: bounds, canvasSize: geo.size)
                    ZoomedImageLayer(image: image, imageRect: rect, zoom: zoom)
                    if session.activeTool == .none, !session.isPickingWhiteBalance {
                        HandToolLayer(zoom: zoom)
                    }
                    overlay(imageRect: rect)
                        .frame(width: geo.size.width, height: geo.size.height)
                    if session.isPickingWhiteBalance {
                        WhiteBalancePickerOverlay(session: session, imageRect: rect)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    if zoom.spaceHeld, session.activeTool != .crop {
                        HandToolLayer(zoom: zoom)
                    }
                    if zoom.isZoomed {
                        ZoomNavigator(image: image, zoom: zoom)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                    }
                    if session.showBefore { BeforeBadge() }
                } else if let error = session.loadError {
                    Text(error).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ZoomHUD(zoom: zoom)
            }
            .background(WindowReader { zoom.window = $0 })
            .onAppear {
                updatePixelSize(bounds.size)
                zoom.canvasFrame = geo.frame(in: .global)
            }
            .onChange(of: geo.size) { _, _ in updatePixelSize(bounds.size) }
            .onChange(of: displayScale) { _, _ in updatePixelSize(bounds.size) }
            .onChange(of: geo.frame(in: .global)) { _, frame in zoom.canvasFrame = frame }
            .onChange(of: LayoutKey(size: geo.size, displayed: displayed, scale: displayScale), initial: true) { _, key in
                zoom.setLayout(canvasSize: key.size, displayedSize: key.displayed, displayScale: key.scale, margin: margin)
            }
            .onChange(of: inputsKey(displayed: displayed), initial: true) { _, _ in
                zoom.setInputs(renderInputs(displayed: displayed))
            }
        }
        .clipped()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { model.moveFocus(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveFocus(by: 1); return .handled }
        .onChange(of: session.activeTool, initial: true) { _, tool in zoom.isLocked = tool == .crop }
        .zoomEventMonitor(zoom) { [model] in model.mode == .develop && !FullScreenPreview.shared.isShowing }
    }

    /// Where the whole displayed image is drawn (zoomed / panned); aspect-fit until the zoom
    /// controller knows the layout.
    private func imageRect(for image: CGImage, bounds: CGRect, canvasSize: CGSize) -> CGRect {
        let r = zoom.imageRect
        if zoom.viewport.isValid, zoom.viewport.canvasSize == canvasSize, r.width > 0 { return r }
        return CanvasGeometry.aspectFitRect(imageSize: CGSize(width: image.width, height: image.height), in: bounds)
    }

    @ViewBuilder
    private func overlay(imageRect: CGRect) -> some View {
        switch session.activeTool {
        case .crop: CropOverlayView(session: session, imageRect: imageRect)
        case .mask: MaskOverlayView(session: session, imageRect: imageRect)
        case .none: Color.clear.allowsHitTesting(false)
        }
    }

    private func updatePixelSize(_ size: CGSize) {
        session.viewPixelSize = CGSize(width: (size.width * displayScale).rounded(),
                                       height: (size.height * displayScale).rounded())
    }

    // MARK: - Zoom inputs

    private struct LayoutKey: Equatable {
        let size: CGSize
        let displayed: CGSize
        let scale: CGFloat
    }

    private struct InputsKey: Equatable {
        let photoID: Int64
        let source: ObjectIdentifier?
        let settings: EditSettings
        let applyCrop: Bool
        let baseWidth: Int
    }

    private func inputsKey(displayed: CGSize) -> InputsKey {
        InputsKey(photoID: session.photo.id, source: session.source.map(ObjectIdentifier.init),
                  settings: session.zoomDisplaySettings, applyCrop: session.renderedWithCrop,
                  baseWidth: session.renderedImage?.width ?? 0)
    }

    private func renderInputs(displayed: CGSize) -> ZoomRenderInputs? {
        guard let source = session.source, let image = session.renderedImage, displayed.width > 0 else { return nil }
        return ZoomRenderInputs(photoID: session.photo.id, source: source, settings: session.zoomDisplaySettings,
                                applyCrop: session.renderedWithCrop, baseRatio: CGFloat(image.width) / displayed.width)
    }
}

extension DevelopSession {
    /// Settings the canvas shows (Before = defaults with the same geometry), for zoomed tiles.
    var zoomDisplaySettings: EditSettings {
        guard showBefore else { return settings }
        var before = EditSettings()
        before.geometry = settings.geometry
        return before
    }
}

/// Reports the hosting NSWindow of this view (for event monitors).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReaderView)?.onWindow = onWindow
    }

    private final class WindowReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
