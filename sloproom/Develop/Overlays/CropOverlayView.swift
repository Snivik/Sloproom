//
//  CropOverlayView.swift
//  sloproom
//
//  Shown while `session.activeTool == .crop`. The canvas then displays the UNCROPPED frame
//  (rotated + flipped + straightened), so `viewRect(fromFrame: geometry.crop)` is the crop
//  rectangle. Draws the darkened outside, border, handles and grid, and handles dragging:
//    corner / edge  resize (aspect lock respected; ⇧ toggles it for the drag)
//    inside         move
//    outside        rotate (straighten)
//  All constraint math is in CropMath (frame pixels); the crop never leaves the rotated image.
//

import AppKit
import SwiftUI

struct CropOverlayView: View {
    let session: DevelopSession
    /// Where the displayed (uncropped) image is drawn, in this view's coordinates.
    let imageRect: CGRect

    @State private var drag: DragState?
    @State private var hover: CropHandle?

    private struct DragState {
        let handle: CropHandle
        /// Crop at drag start, full-res frame pixels.
        let startCrop: CGRect
        let startPoint: CGPoint
        let startAngle: Double
        /// Pointer angle around the crop center at drag start (rotate), radians.
        let startPointerAngle: CGFloat
    }

    var body: some View {
        let g = session.canvasGeometry(imageRect: imageRect)
        if isShowingFrame(g) {
            let crop = g.viewRect(fromFrame: session.settings.geometry.crop)
            Canvas { ctx, size in draw(in: &ctx, size: size, crop: crop) }
                .contentShape(Rectangle())
                .gesture(dragGesture(g))
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hover = Self.handle(at: p, crop: crop) } else { hover = nil }
                }
                .pointerStyle(pointerStyle(drag?.handle ?? hover))
        } else {
            // The uncropped render hasn't arrived yet (or is stale after a turn).
            Color.clear.allowsHitTesting(false)
        }
    }

    /// True once the canvas shows the uncropped frame for the current turns.
    private func isShowingFrame(_ g: CanvasGeometry) -> Bool {
        guard !g.showsCrop, imageRect.width > 0, imageRect.height > 0 else { return false }
        let f = g.math.frameSize
        guard f.width > 0, f.height > 0 else { return false }
        return abs((imageRect.width / imageRect.height) / (f.width / f.height) - 1) < 0.02
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, size: CGSize, crop: CGRect) {
        // Darken outside the crop (over the image and the empty straighten corners).
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addRect(crop)
        ctx.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))

        // Grid while interacting.
        let tool = session.cropTool
        if tool.isInteracting, tool.gridMode != .none {
            let n = tool.isRotating ? 12 : tool.gridMode == .thirds ? 3 : 6
            var grid = Path()
            for i in 1..<n {
                let t = CGFloat(i) / CGFloat(n)
                grid.move(to: CGPoint(x: crop.minX + crop.width * t, y: crop.minY))
                grid.addLine(to: CGPoint(x: crop.minX + crop.width * t, y: crop.maxY))
                grid.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * t))
                grid.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * t))
            }
            ctx.stroke(grid, with: .color(.white.opacity(tool.isRotating ? 0.35 : 0.55)), lineWidth: 0.5)
        }

        ctx.stroke(Path(crop), with: .color(.white.opacity(0.9)), lineWidth: 1)

        // Corner brackets + edge ticks.
        let arm = min(18, crop.width / 3, crop.height / 3)
        var handles = Path()
        for (corner, dx, dy) in [(CGPoint(x: crop.minX, y: crop.minY), 1.0, 1.0), (CGPoint(x: crop.maxX, y: crop.minY), -1.0, 1.0),
                                 (CGPoint(x: crop.maxX, y: crop.maxY), -1.0, -1.0), (CGPoint(x: crop.minX, y: crop.maxY), 1.0, -1.0)] {
            handles.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            handles.addLine(to: corner)
            handles.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        let tick = min(10, crop.width / 4, crop.height / 4)
        handles.move(to: CGPoint(x: crop.midX - tick, y: crop.minY)); handles.addLine(to: CGPoint(x: crop.midX + tick, y: crop.minY))
        handles.move(to: CGPoint(x: crop.midX - tick, y: crop.maxY)); handles.addLine(to: CGPoint(x: crop.midX + tick, y: crop.maxY))
        handles.move(to: CGPoint(x: crop.minX, y: crop.midY - tick)); handles.addLine(to: CGPoint(x: crop.minX, y: crop.midY + tick))
        handles.move(to: CGPoint(x: crop.maxX, y: crop.midY - tick)); handles.addLine(to: CGPoint(x: crop.maxX, y: crop.midY + tick))
        ctx.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .square))
    }

    // MARK: Hit testing

    static func handle(at p: CGPoint, crop: CGRect) -> CropHandle {
        let r: CGFloat = 10
        let nearL = abs(p.x - crop.minX) <= r, nearR = abs(p.x - crop.maxX) <= r
        let nearT = abs(p.y - crop.minY) <= r, nearB = abs(p.y - crop.maxY) <= r
        let inX = p.x >= crop.minX - r && p.x <= crop.maxX + r
        let inY = p.y >= crop.minY - r && p.y <= crop.maxY + r
        switch (nearL, nearR, nearT, nearB) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (_, true, _, true): return .bottomRight
        case (true, _, _, true): return .bottomLeft
        default: break
        }
        if nearT, inX { return .top }
        if nearB, inX { return .bottom }
        if nearL, inY { return .left }
        if nearR, inY { return .right }
        return crop.contains(p) ? .inside : .outside
    }

    private func pointerStyle(_ handle: CropHandle?) -> PointerStyle? {
        switch handle {
        case .topLeft: .frameResize(position: .topLeading)
        case .top: .frameResize(position: .top)
        case .topRight: .frameResize(position: .topTrailing)
        case .right: .frameResize(position: .trailing)
        case .bottomRight: .frameResize(position: .bottomTrailing)
        case .bottom: .frameResize(position: .bottom)
        case .bottomLeft: .frameResize(position: .bottomLeading)
        case .left: .frameResize(position: .leading)
        case .inside: drag == nil ? .grabIdle : .grabActive
        case .outside, nil: nil
        }
    }

    // MARK: Dragging

    private func dragGesture(_ g: CanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil { beginDrag(at: value.startLocation, g) }
                if let drag { update(drag, to: value.location, g) }
            }
            .onEnded { _ in
                if drag?.handle == .outside { session.endStraighten() } else { session.commitUndoGroup() }
                drag = nil
                session.cropTool.isInteracting = false
                session.cropTool.isRotating = false
            }
    }

    /// View point -> full-res frame pixels.
    private func framePixel(_ p: CGPoint, _ g: CanvasGeometry) -> CGPoint {
        let n = g.framePoint(fromView: p)
        return CGPoint(x: n.x * g.math.frameSize.width, y: n.y * g.math.frameSize.height)
    }

    private func beginDrag(at p: CGPoint, _ g: CanvasGeometry) {
        let viewCrop = g.viewRect(fromFrame: session.settings.geometry.crop)
        let handle = Self.handle(at: p, crop: viewCrop)
        session.commitUndoGroup()
        if handle == .outside { session.beginStraighten() }
        drag = DragState(handle: handle, startCrop: session.cropPixelRect, startPoint: framePixel(p, g),
                         startAngle: session.settings.geometry.straightenAngle,
                         startPointerAngle: atan2(p.y - viewCrop.midY, p.x - viewCrop.midX))
        session.cropTool.isInteracting = true
        session.cropTool.isRotating = handle == .outside
    }

    private func update(_ d: DragState, to p: CGPoint, _ g: CanvasGeometry) {
        switch d.handle {
        case .outside:
            // Angle swept around the crop center (y down: positive = clockwise).
            let viewCrop = g.viewRect(fromFrame: session.settings.geometry.crop)
            var delta = atan2(p.y - viewCrop.midY, p.x - viewCrop.midX) - d.startPointerAngle
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            session.setStraighten(d.startAngle + Double(delta) * 180 / .pi)
        case .inside:
            let q = framePixel(p, g)
            let math = session.cropMath()
            let moved = math.moved(d.startCrop, by: CGVector(dx: q.x - d.startPoint.x, dy: q.y - d.startPoint.y))
            session.settings.geometry.crop = math.normRect(moved)
        default:
            let math = session.cropMath()
            let locked = session.settings.geometry.aspectLocked != NSEvent.modifierFlags.contains(.shift)
            // Minimum crop: ~24 view points.
            let minSize = 24 / max(g.viewScale, 1e-6)
            let rect = math.resized(d.startCrop, handle: d.handle, to: framePixel(p, g), lockAspect: locked, minSize: minSize)
            var geo = session.settings.geometry
            geo.crop = math.normRect(rect)
            if !locked { geo.cropPresetID = nil }
            session.settings.geometry = geo
        }
    }
}
