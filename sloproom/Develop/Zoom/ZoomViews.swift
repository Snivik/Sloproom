//
//  ZoomViews.swift
//  sloproom
//
//  Building blocks of a zoomable canvas (Develop canvas and full-screen preview):
//    ZoomedImageLayer   the base image at `zoom.imageRect` + the sharp region tile over it
//    HandToolLayer      drag = pan (hand), click = toggle Fit ↔ zoom at the point
//    ZoomHUD            transient "100%" badge
//    ZoomNavigator      mini map (top right while zoomed): visible rect, click/drag to pan
//

import SwiftUI

/// Draws `image` (the whole displayed image) at `imageRect` (normally `zoom.imageRect`) and the refine tile over it.
/// Lay out over the whole canvas (top-left origin).
struct ZoomedImageLayer: View {
    let image: CGImage
    let imageRect: CGRect
    let zoom: ZoomController

    var body: some View {
        let rect = imageRect
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            if let tile = zoom.visibleTile {
                let n = tile.normalizedRect
                let r = CGRect(x: rect.minX + n.minX * rect.width, y: rect.minY + n.minY * rect.height,
                               width: n.width * rect.width, height: n.height * rect.height)
                Image(decorative: tile.image, scale: 1)
                    .resizable()
                    // Past 1:1 show real pixels (Lightroom does too); below, smooth.
                    .interpolation(zoom.viewport.pixelRatio > 1.01 ? .none : .high)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hand tool: drag pans when zoomed; a click (no drag) toggles Fit ↔ zoom at that point.
/// `enabled` false = transparent to events.
struct HandToolLayer: View {
    let zoom: ZoomController
    var clickToZoom = true

    @State private var last: CGPoint?
    @State private var moved = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !moved, hypot(value.translation.width, value.translation.height) > 3 { moved = true }
                        guard moved else { return }
                        let prev = last ?? value.startLocation
                        zoom.isPanning = true
                        zoom.pan(by: CGSize(width: value.location.x - prev.x, height: value.location.y - prev.y))
                        last = value.location
                    }
                    .onEnded { value in
                        if !moved, clickToZoom, !zoom.isLocked { zoom.toggle(at: value.location) }
                        zoom.isPanning = false
                        moved = false
                        last = nil
                    }
            )
            .pointerStyle(zoom.isPanning ? .grabActive : zoom.isZoomed ? .grabIdle : (clickToZoom ? .zoomIn : nil))
    }
}

/// Transient zoom badge ("Fit", "100%") at the bottom center of the canvas.
struct ZoomHUD: View {
    let zoom: ZoomController

    var body: some View {
        VStack {
            Spacer()
            if let text = zoom.hudText {
                Text(text)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: zoom.hudText)
        .allowsHitTesting(false)
    }
}

/// Mini navigator: the whole image with the visible rect; click / drag in it to pan there.
struct ZoomNavigator: View {
    let image: CGImage
    let zoom: ZoomController
    var maxSide: CGFloat = 170

    var body: some View {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = maxSide / max(w, h, 1)
        let size = CGSize(width: w * s, height: h * s)
        let v = zoom.viewport.visibleDisplayedRect
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .frame(width: size.width, height: size.height)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .background(Rectangle().stroke(.black.opacity(0.5), lineWidth: 3))
                .frame(width: max(4, v.width * size.width), height: max(4, v.height * size.height))
                .offset(x: v.minX * size.width, y: v.minY * size.height)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            // Center the view on the clicked point.
            let r = zoom.imageRect
            let target = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
            let now = zoom.viewport.clampedCenter
            zoom.pan(by: CGSize(width: (now.x - target.x) * r.width, height: (now.y - target.y) * r.height))
        })
        .padding(4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }
}
