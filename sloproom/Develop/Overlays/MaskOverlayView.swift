//
//  MaskOverlayView.swift
//  sloproom
//
//  Mask tool overlay (shown while `session.activeTool == .mask`; the canvas shows the cropped
//  image). Draws pins, the selected mask's lines / handles, the brush cursor and the red
//  coverage overlay; forwards drags to MaskInteraction (hit testing + editing).
//
//  Keys (the overlay takes focus): O overlay, [ / ] brush size, Esc cancel creation / leave
//  the tool, ⌫ delete the selected mask. ⌥ while painting erases.
//

import AppKit
import SwiftUI

struct MaskOverlayView: View {
    let session: DevelopSession
    /// Where the displayed image is drawn, in this view's coordinates.
    let imageRect: CGRect

    @State private var tool = MaskToolState.shared
    @State private var coverage = MaskCoverageRenderer()
    @State private var interaction = MaskInteraction()
    @State private var cursor: CGPoint?
    @FocusState private var focused: Bool

    var body: some View {
        let space = MaskSpace(geometry: session.canvasGeometry(imageRect: imageRect))
        ZStack(alignment: .topLeading) {
            if tool.showOverlay, let image = coverage.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .allowsHitTesting(false)
            }
            Canvas { ctx, _ in draw(&ctx, space: space) }
        }
        .contentShape(Rectangle())
        .pointerStyle(isBrushing || tool.pendingKind != nil ? .rectSelection : nil)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    focused = true
                    cursor = value.location
                    interaction.dragChanged(start: value.startLocation, location: value.location, space: space,
                                            session: session, tool: tool, erase: eraseRequested)
                }
                .onEnded { value in
                    interaction.dragEnded(location: value.location, space: space, session: session)
                }
        )
        .onContinuousHover { phase in
            if case .active(let p) = phase { cursor = p } else if !interaction.isDragging { cursor = nil }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if tool.pendingKind != nil { tool.pendingKind = nil } else { session.finishMasking() }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "oO[]")) { press in
            switch press.characters {
            case "[": tool.stepBrushSize(up: false)
            case "]": tool.stepBrushSize(up: true)
            default: tool.showOverlay.toggle()
            }
            return .handled
        }
        // Backspace arrives as U+007F, which `onKeyPress(.delete)` (U+0008) doesn't match on macOS.
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}\u{8}")) { _ in deleteSelected() }
        .onKeyPress(.deleteForward) { deleteSelected() }
        .onAppear { focused = true }
        .onDisappear { tool.pendingKind = nil }
        .onChange(of: coverageRequest, initial: true) { _, request in
            if let request { coverage.request(request) } else { coverage.clear() }
        }
    }

    private var eraseRequested: Bool { tool.eraseMode || NSEvent.modifierFlags.contains(.option) }

    private var coverageRequest: MaskCoverageRenderer.Request? {
        guard tool.showOverlay, let mask = session.selectedMask else { return nil }
        return .init(mask: mask, geometry: session.settings.geometry, fullSize: session.orientedSize,
                     targetSize: session.viewPixelSize)
    }

    private func deleteSelected() -> KeyPress.Result {
        guard let id = session.selectedMaskID else { return .ignored }
        session.deleteMask(id)
        return .handled
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, space: MaskSpace) {
        guard space.isValid else { return }
        let selected = tool.pendingKind == nil ? session.selectedMask : nil
        var clipped = ctx
        clipped.clip(to: Path(imageRect))
        if let m = selected?.linear { drawLinear(m, lines: clipped, handles: ctx, space: space) }
        if let m = selected?.radial { drawRadial(m, ctx: ctx, space: space) }
        for mask in session.settings.masks {
            guard let p = mask.pinPoint else { continue }
            drawPin(space.view(space.px(p)), selected: mask.id == session.selectedMaskID, enabled: mask.isEnabled, in: ctx)
        }
        if isBrushing, let c = cursor { drawBrushCursor(at: c, space: space, in: ctx) }
    }

    private var isBrushing: Bool {
        tool.pendingKind == .brush || (tool.pendingKind == nil && session.selectedMask?.brush != nil)
    }

    private func drawLinear(_ m: LinearGradientMask, lines: GraphicsContext, handles: GraphicsContext, space: MaskSpace) {
        let h = LinearHandles(m, space: space)
        outline(segment(h.viewLine(through: h.start)), in: lines)
        outline(segment(h.viewLine(through: h.mid)), in: lines)
        outline(segment(h.viewLine(through: h.end)), in: lines, dash: [5, 4])
        outline(segment((space.view(h.mid), h.rotateHandle)), in: handles, width: 0.75)
        drawHandle(h.rotateHandle, round: true, in: handles)
    }

    private func drawRadial(_ m: RadialGradientMask, ctx: GraphicsContext, space: MaskSpace) {
        let h = RadialHandles(m, space: space)
        outline(polygon(h.viewEllipse(scale: 1)), in: ctx)
        let inner = 1 - min(max(m.feather, 0), 100) / 100
        if inner > 0.02 { outline(polygon(h.viewEllipse(scale: inner)), in: ctx, dash: [4, 4]) }
        for p in [h.xPlus, h.xMinus, h.yPlus, h.yMinus] { drawHandle(space.view(p), round: false, in: ctx) }
        outline(segment((space.view(h.yMinus), h.rotateHandle)), in: ctx, width: 0.75)
        drawHandle(h.rotateHandle, round: true, in: ctx)
    }

    private func drawBrushCursor(at c: CGPoint, space: MaskSpace, in ctx: GraphicsContext) {
        let outer = space.geometry.viewLength(fromSourceWidthFraction: tool.brushRadius)
        let inner = outer * (1 - tool.brushFeather / 100)
        outline(Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer)), in: ctx)
        if inner > 1 {
            outline(Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner)), in: ctx, dash: [3, 3])
        }
        if interaction.isErasing || (!interaction.isDragging && eraseRequested) {
            outline(segment((CGPoint(x: c.x - 4, y: c.y), CGPoint(x: c.x + 4, y: c.y))), in: ctx, width: 1.5)
        }
    }

    private func segment(_ ends: (CGPoint, CGPoint)) -> Path {
        var p = Path()
        p.move(to: ends.0)
        p.addLine(to: ends.1)
        return p
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        return p
    }

    private func outline(_ path: Path, in ctx: GraphicsContext, width: CGFloat = 1, dash: [CGFloat] = []) {
        ctx.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: width + 2, lineCap: .round, dash: dash))
        ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func drawHandle(_ p: CGPoint, round: Bool, in ctx: GraphicsContext) {
        let r: CGFloat = 4
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let path = round ? Path(ellipseIn: rect) : Path(rect)
        ctx.fill(path, with: .color(.white))
        ctx.stroke(path, with: .color(.black.opacity(0.7)), lineWidth: 1)
    }

    private func drawPin(_ p: CGPoint, selected: Bool, enabled: Bool, in ctx: GraphicsContext) {
        let r: CGFloat = selected ? 7 : 5.5
        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(dot, with: .color(selected ? .accentColor : .white.opacity(enabled ? 1 : 0.5)))
        ctx.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 1)
        if selected {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.white))
        }
    }
}
