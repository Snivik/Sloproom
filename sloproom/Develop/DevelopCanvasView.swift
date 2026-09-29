//
//  DevelopCanvasView.swift
//  sloproom
//
//  Shows `session.renderedImage` aspect-fit and hosts the tool overlay.
//
//  Overlay contract: overlays are laid out over the WHOLE canvas (same coordinate space as
//  this view, top-left origin) and receive `imageRect` = where the image is drawn in that
//  space. Convert with `session.canvasGeometry(imageRect:)` (see CanvasGeometry).
//  While the crop tool is active the displayed image is the UNCROPPED frame.
//

import SwiftUI

struct DevelopCanvasView: View {
    let session: DevelopSession
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    private let margin: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: margin, dy: margin)
            ZStack(alignment: .topLeading) {
                Color(white: 0.12)
                if let image = session.renderedImage {
                    let rect = CanvasGeometry.aspectFitRect(imageSize: CGSize(width: image.width, height: image.height), in: bounds)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    overlay(imageRect: rect)
                        .frame(width: geo.size.width, height: geo.size.height)
                    if session.isPickingWhiteBalance {
                        WhiteBalancePickerOverlay(session: session, imageRect: rect)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    if session.showBefore { BeforeBadge() }
                } else if let error = session.loadError {
                    Text(error).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { updatePixelSize(bounds.size) }
            .onChange(of: geo.size) { _, _ in updatePixelSize(bounds.size) }
            .onChange(of: displayScale) { _, _ in updatePixelSize(bounds.size) }
        }
        .clipped()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { model.moveFocus(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveFocus(by: 1); return .handled }
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
}
