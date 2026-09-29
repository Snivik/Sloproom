//
//  MaskInteraction.swift
//  sloproom
//
//  Mouse interaction of the mask tool, kept out of the SwiftUI view so the harness can drive
//  it (Tools/masks_check.swift). MaskOverlayView feeds it drag events in view coordinates.
//
//  Editing math is done in SOURCE PIXELS (oriented, uncropped, full resolution) so angles and
//  distances are aspect-correct; `MaskSpace` converts to/from view coordinates through
//  CanvasGeometry, so crop / rotate / flip are handled for free.
//
//  - Pins: click one to select that mask (drag to move linear / radial).
//  - Linear: drag the center pin or line to move, the start / end line to change the feather
//    width, the handle on the center line to rotate.
//  - Radial: side handles resize X / Y, the top handle rotates, dragging inside moves.
//  - Brush: paints strokes (points decimated while painting, simplified at the end);
//    `erase` (⌥ or Erase mode) paints eraser strokes.
//  - Pending creation: a drag creates the shape (a click creates a default size).
//

import Foundation
import CoreGraphics

struct MaskInteraction {
    enum DragOp {
        /// Creating a mask of a kind; the id is set once the mask exists.
        case create(MaskKind, UUID?)
        case move(UUID, original: Mask, from: CGPoint)
        case linearStart(UUID), linearEnd(UUID), linearRotate(UUID)
        case radialX(UUID), radialY(UUID), radialRotate(UUID)
        /// Painting `stroke` into mask id (nil = create the brush mask); `appended` once stored.
        case paint(UUID?, BrushStroke, appended: Bool)
        /// The drag started on nothing editable.
        case idle
    }

    static let hitRadius: CGFloat = 8

    private(set) var op: DragOp?
    var isDragging: Bool { op != nil }

    /// Eraser stroke in progress?
    var isErasing: Bool {
        if case .paint(_, let stroke, _)? = op { return stroke.isEraser }
        return false
    }

    // MARK: Events

    mutating func dragChanged(start: CGPoint, location: CGPoint, space: MaskSpace, session: DevelopSession,
                              tool: MaskToolState, erase: Bool) {
        guard space.isValid else { return }
        if op == nil {
            session.commitUndoGroup()
            op = beginDrag(at: start, space: space, session: session, tool: tool, erase: erase)
        }
        guard let current = op else { return }
        let p = space.pixel(fromView: location)
        let a = space.pixel(fromView: start)
        let moved = hypot(location.x - start.x, location.y - start.y) > 3

        switch current {
        case .create(let kind, let id):
            guard moved else { return }
            if let id { updateCreated(kind, id: id, from: a, to: p, space: space, session: session) }
            else { op = .create(kind, createMask(kind, from: a, to: p, space: space, session: session)) }
        case .move(let id, let original, let from):
            let d = MaskVec(p) - MaskVec(from)
            session.updateMask(id) { m in
                if var l = original.linear {
                    l.start = space.norm((MaskVec(space.px(l.start)) + d).cg)
                    l.end = space.norm((MaskVec(space.px(l.end)) + d).cg)
                    m.linear = l
                } else if var r = original.radial {
                    r.center = space.norm((MaskVec(space.px(r.center)) + d).cg)
                    m.radial = r
                }
            }
        case .linearStart(let id), .linearEnd(let id), .linearRotate(let id):
            session.updateMask(id) { m in
                guard let l = m.linear else { return }
                m.linear = Self.editLinear(l, op: current, to: p, space: space)
            }
        case .radialX(let id), .radialY(let id), .radialRotate(let id):
            session.updateMask(id) { m in
                guard let r = m.radial else { return }
                m.radial = Self.editRadial(r, op: current, to: p, space: space)
            }
        case .paint(let id, var stroke, let appended):
            if MaskEditing.append(space.norm(p), to: &stroke, aspect: space.aspect) || !appended {
                op = .paint(store(stroke, in: id, appended: appended, session: session), stroke, appended: true)
            } else {
                op = .paint(id, stroke, appended: appended)
            }
        case .idle:
            break
        }
    }

    mutating func dragEnded(location: CGPoint, space: MaskSpace, session: DevelopSession) {
        defer {
            op = nil
            session.commitUndoGroup()
        }
        guard space.isValid, let current = op else { return }
        let p = space.pixel(fromView: location)
        switch current {
        case .create(let kind, nil):
            // A click without dragging: default-sized shape at the click point.
            let to = kind == .linear ? CGPoint(x: p.x, y: p.y + 0.25 * space.h) : CGPoint(x: p.x + 0.15 * space.w, y: p.y + 0.15 * space.w)
            createMask(kind, from: p, to: to, space: space, session: session)
        case .paint(let id, var stroke, let appended):
            MaskEditing.append(space.norm(p), to: &stroke, aspect: space.aspect, force: true)
            MaskEditing.finish(&stroke, aspect: space.aspect)
            store(stroke, in: id, appended: appended, session: session)
        default:
            break
        }
    }

    // MARK: Hit testing

    private func beginDrag(at v: CGPoint, space: MaskSpace, session: DevelopSession, tool: MaskToolState, erase: Bool) -> DragOp {
        if let kind = tool.pendingKind {
            return kind == .brush ? beginPaint(nil, tool: tool, erase: erase) : .create(kind, nil)
        }
        let selected = session.selectedMask
        if let m = selected, let hit = Self.handleHit(m, at: v, space: space) { return hit }
        // Pins of the other masks: select (and move) them.
        for mask in session.settings.masks.reversed() where mask.id != selected?.id {
            guard let pin = mask.pinPoint, MaskVec(space.view(space.px(pin))).distance(to: MaskVec(v)) <= Self.hitRadius else { continue }
            session.selectMask(mask.id)
            return mask.brush != nil ? .idle : .move(mask.id, original: mask, from: space.pixel(fromView: v))
        }
        if let m = selected, m.brush != nil { return beginPaint(m.id, tool: tool, erase: erase) }
        return .idle
    }

    private func beginPaint(_ id: UUID?, tool: MaskToolState, erase: Bool) -> DragOp {
        var stroke = BrushStroke()
        stroke.radius = tool.brushRadius
        stroke.feather = tool.brushFeather
        stroke.flow = tool.brushFlow
        stroke.isEraser = erase
        if erase && id == nil { return .idle } // nothing to erase from
        return .paint(id, stroke, appended: false)
    }

    /// Hit-tests the selected mask's handles (view coordinates).
    static func handleHit(_ mask: Mask, at v: CGPoint, space: MaskSpace) -> DragOp? {
        let pv = MaskVec(v)
        let from = space.pixel(fromView: v)
        func near(_ q: CGPoint) -> Bool { MaskVec(q).distance(to: pv) <= hitRadius }
        if let l = mask.linear {
            let h = LinearHandles(l, space: space)
            if near(h.rotateHandle) { return .linearRotate(mask.id) }
            if near(space.view(h.mid)) { return .move(mask.id, original: mask, from: from) }
            let ds = h.viewDistance(v, toLineThrough: h.start), de = h.viewDistance(v, toLineThrough: h.end)
            if min(ds, de) <= hitRadius { return ds <= de ? .linearStart(mask.id) : .linearEnd(mask.id) }
            if h.viewDistance(v, toLineThrough: h.mid) <= hitRadius { return .move(mask.id, original: mask, from: from) }
        } else if let r = mask.radial {
            let h = RadialHandles(r, space: space)
            if near(h.rotateHandle) { return .radialRotate(mask.id) }
            if near(space.view(h.xPlus)) || near(space.view(h.xMinus)) { return .radialX(mask.id) }
            if near(space.view(h.yPlus)) || near(space.view(h.yMinus)) { return .radialY(mask.id) }
            if h.contains(from) { return .move(mask.id, original: mask, from: from) }
        }
        return nil
    }

    // MARK: Edits (source pixels)

    @discardableResult
    private func createMask(_ kind: MaskKind, from a: CGPoint, to b: CGPoint, space: MaskSpace, session: DevelopSession) -> UUID {
        switch kind {
        case .linear:
            return session.addMask(.linear(LinearGradientMask(start: space.norm(a), end: space.norm(b))))
        case .radial:
            var r = RadialGradientMask()
            r.center = space.norm(a)
            (r.radiusX, r.radiusY) = Self.radii(from: a, to: b, space: space)
            return session.addMask(.radial(r))
        case .brush:
            return session.addMask(.brush(BrushMask()))
        }
    }

    private func updateCreated(_ kind: MaskKind, id: UUID, from a: CGPoint, to b: CGPoint, space: MaskSpace, session: DevelopSession) {
        session.updateMask(id) { m in
            if var l = m.linear, kind == .linear {
                l.end = space.norm(b)
                m.linear = l
            } else if var r = m.radial, kind == .radial {
                (r.radiusX, r.radiusY) = Self.radii(from: a, to: b, space: space)
                m.radial = r
            }
        }
    }

    private static func radii(from a: CGPoint, to b: CGPoint, space: MaskSpace) -> (Double, Double) {
        let minPx = 0.01 * space.w
        return (Double(max(abs(b.x - a.x), minPx) / space.w), Double(max(abs(b.y - a.y), minPx) / space.h))
    }

    static func editLinear(_ l: LinearGradientMask, op: DragOp, to p: CGPoint, space: MaskSpace) -> LinearGradientMask {
        let h = LinearHandles(l, space: space)
        let s = MaskVec(h.start), e = MaskVec(h.end), pv = MaskVec(p)
        let minLength = 0.002 * Double(space.w)
        var out = l
        switch op {
        case .linearStart:
            out.start = space.norm((e - h.dir * max((e - pv).dot(h.dir), minLength)).cg)
        case .linearEnd:
            out.end = space.norm((s + h.dir * max((pv - s).dot(h.dir), minLength)).cg)
        case .linearRotate:
            let m = MaskVec(h.mid)
            guard let perp = (pv - m).normalized else { return l }
            let dir = MaskVec(x: perp.y, y: -perp.x) // inverse of perp = (-dir.y, dir.x)
            let half = (e - s).length / 2
            out.start = space.norm((m - dir * half).cg)
            out.end = space.norm((m + dir * half).cg)
        default: break
        }
        return out
    }

    static func editRadial(_ r: RadialGradientMask, op: DragOp, to p: CGPoint, space: MaskSpace) -> RadialGradientMask {
        let h = RadialHandles(r, space: space)
        let d = MaskVec(p) - MaskVec(h.center)
        let minPx = 0.005 * Double(space.w)
        var out = r
        switch op {
        case .radialX: out.radiusX = max(abs(d.dot(h.ux)), minPx) / Double(space.w)
        case .radialY: out.radiusY = max(abs(d.dot(h.uy)), minPx) / Double(space.h)
        case .radialRotate:
            // The handle sits on -uy (angle θ - 90°).
            var deg = atan2(d.y, d.x) * 180 / .pi + 90
            if deg > 180 { deg -= 360 }
            out.rotation = deg
        default: break
        }
        return out
    }

    /// Stores the in-progress stroke (creating the brush mask on first use). Returns the mask id.
    @discardableResult
    private func store(_ stroke: BrushStroke, in id: UUID?, appended: Bool, session: DevelopSession) -> UUID? {
        guard let id else {
            var brush = BrushMask()
            brush.strokes = [stroke]
            return session.addMask(.brush(brush))
        }
        session.updateMask(id) { m in
            guard var b = m.brush else { return }
            if appended, !b.strokes.isEmpty { b.strokes[b.strokes.count - 1] = stroke } else { b.strokes.append(stroke) }
            m.brush = b
        }
        return id
    }
}

// MARK: - Geometry helpers

/// Mask space <-> source pixels <-> view.
struct MaskSpace {
    let geometry: CanvasGeometry
    var w: CGFloat { geometry.math.sourceSize.width }
    var h: CGFloat { geometry.math.sourceSize.height }
    var isValid: Bool { w > 0 && h > 0 && geometry.imageRect.width > 0 }
    /// height / width (converts normalized y distances to width units).
    var aspect: Double { Double(h / w) }

    func px(_ p: NormPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
    func norm(_ q: CGPoint) -> NormPoint { NormPoint(x: Double(q.x / w), y: Double(q.y / h)) }
    func view(_ q: CGPoint) -> CGPoint { geometry.viewPoint(fromMask: norm(q)) }
    func pixel(fromView v: CGPoint) -> CGPoint { px(geometry.maskPoint(fromView: v)) }
}

/// Linear gradient lines and handles (source pixels unless noted).
struct LinearHandles {
    let space: MaskSpace
    let start: CGPoint, end: CGPoint, mid: CGPoint
    /// Unit direction start -> end and its perpendicular.
    let dir: MaskVec, perp: MaskVec

    init(_ m: LinearGradientMask, space: MaskSpace) {
        self.space = space
        start = space.px(m.start)
        end = space.px(m.end)
        mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        dir = (MaskVec(end) - MaskVec(start)).normalized ?? MaskVec(x: 0, y: 1)
        perp = MaskVec(x: -dir.y, y: dir.x)
    }

    /// View endpoints of a long line through `p` perpendicular to the gradient (clip it to the image).
    func viewLine(through p: CGPoint) -> (CGPoint, CGPoint) {
        let l = Double(space.w + space.h) * 2
        return (space.view((MaskVec(p) - perp * l).cg), space.view((MaskVec(p) + perp * l).cg))
    }

    func viewDistance(_ v: CGPoint, toLineThrough p: CGPoint) -> CGFloat {
        let a = MaskVec(space.view(p))
        guard let u = (MaskVec(space.view((MaskVec(p) + perp * Double(space.w)).cg)) - a).normalized else { return .infinity }
        let d = MaskVec(v) - a
        return CGFloat(abs(d.x * u.y - d.y * u.x))
    }

    /// Rotation handle (view): on the center line, 44 pt from the center pin.
    var rotateHandle: CGPoint {
        let m = MaskVec(space.view(mid))
        let u = (MaskVec(space.view((MaskVec(mid) + perp * Double(space.w)).cg)) - m).normalized ?? MaskVec(x: 1, y: 0)
        return (m + u * 44).cg
    }
}

/// Radial gradient ellipse and handles (source pixels unless noted).
struct RadialHandles {
    let space: MaskSpace
    let center: CGPoint
    let rx: Double, ry: Double
    /// Ellipse axes (y down, rotated clockwise).
    let ux: MaskVec, uy: MaskVec

    init(_ m: RadialGradientMask, space: MaskSpace) {
        self.space = space
        center = space.px(m.center)
        rx = m.radiusX * Double(space.w)
        ry = m.radiusY * Double(space.h)
        let t = m.rotation * .pi / 180
        ux = MaskVec(x: cos(t), y: sin(t))
        uy = MaskVec(x: -sin(t), y: cos(t))
    }

    var xPlus: CGPoint { (MaskVec(center) + ux * rx).cg }
    var xMinus: CGPoint { (MaskVec(center) - ux * rx).cg }
    var yPlus: CGPoint { (MaskVec(center) + uy * ry).cg }
    var yMinus: CGPoint { (MaskVec(center) - uy * ry).cg }

    /// View polygon of the ellipse scaled by `s` (1 = outer edge).
    func viewEllipse(scale s: Double, segments: Int = 72) -> [CGPoint] {
        (0..<segments).map { k in
            let a = Double(k) / Double(segments) * 2 * .pi
            return space.view((MaskVec(center) + ux * (rx * s * cos(a)) + uy * (ry * s * sin(a))).cg)
        }
    }

    func contains(_ p: CGPoint) -> Bool {
        let d = MaskVec(p) - MaskVec(center)
        let a = d.dot(ux) / max(rx, 1e-9), b = d.dot(uy) / max(ry, 1e-9)
        return a * a + b * b <= 1
    }

    /// Rotation handle (view): 24 pt beyond the top (-y axis) handle.
    var rotateHandle: CGPoint {
        let c = MaskVec(space.view(center)), top = MaskVec(space.view(yMinus))
        let u = (top - c).normalized ?? MaskVec(x: 0, y: -1)
        return (top + u * 24).cg
    }
}

/// Tiny 2D vector (own type, so its operators never clash with other files).
struct MaskVec {
    var x: Double, y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
    var length: Double { hypot(x, y) }
    var normalized: MaskVec? { length > 1e-12 ? MaskVec(x: x / length, y: y / length) : nil }
    func dot(_ o: MaskVec) -> Double { x * o.x + y * o.y }
    func distance(to o: MaskVec) -> CGFloat { CGFloat((self - o).length) }
    static func + (a: MaskVec, b: MaskVec) -> MaskVec { MaskVec(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: MaskVec, b: MaskVec) -> MaskVec { MaskVec(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: MaskVec, k: Double) -> MaskVec { MaskVec(x: a.x * k, y: a.y * k) }
}
