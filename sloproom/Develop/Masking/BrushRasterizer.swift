//
//  BrushRasterizer.swift
//  sloproom
//
//  Rasterizes brush strokes into an 8-bit grayscale bitmap (white = full effect) with
//  CoreGraphics, and caches the result so interactive renders stay fast.
//
//  - Raster size = render size (capped at `maxRasterSide`; larger renders upscale the mask,
//    which is smooth anyway). Radii are fractions of the image WIDTH, so any scale works.
//  - Each stroke is drawn into its own layer as nested round-capped polylines, widest/darkest
//    first: a distance-based falloff from the stroke path (hard core = radius × (1 - feather),
//    smoothstep to 0 at radius). The layer is then composited into the accumulator with
//    `flow` as opacity: paint = source-over white, eraser = source-over black
//    (acc += c·(1 - acc) / acc *= 1 - c).
//  - Cache key = (mask id, hash of strokes, raster size). While painting only the last stroke
//    changes, so the prefix without it is looked up and only the new stroke is drawn.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum BrushRasterizer {
    static let maxRasterSide = 4096

    /// Mask image at `context.imageSize`, or nil if there are no strokes.
    static func maskImage(for brush: BrushMask, id: UUID, context: RenderContext) -> CIImage? {
        guard brush.strokes.contains(where: { !$0.points.isEmpty }) else { return nil }
        let w = context.imageSize.width, h = context.imageSize.height
        let s = min(1, CGFloat(maxRasterSide) / max(w, h))
        let rw = max(1, Int((w * s).rounded())), rh = max(1, Int((h * s).rounded()))
        guard let raster = raster(for: brush, id: id, width: rw, height: rh) else { return nil }
        var image = CIImage(cgImage: raster, options: [.colorSpace: NSNull()])
        if rw != Int(w) || rh != Int(h) {
            image = image.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: w / CGFloat(rw), y: h / CGFloat(rh)))
        }
        return image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Grayscale raster of all strokes (cached).
    static func raster(for brush: BrushMask, id: UUID, width: Int, height: Int) -> CGImage? {
        let hashes = prefixHashes(brush.strokes)
        let n = brush.strokes.count
        let key = Key(id: id, hash: hashes[n], width: width, height: height)
        if let hit = cache.get(key) { return makeImage(hit, width: width, height: height) }

        // Start from the cached prefix (all strokes but the last) when painting.
        var pixels: Data
        var first = 0
        if n > 1, let prefix = cache.get(Key(id: id, hash: hashes[n - 1], width: width, height: height)) {
            pixels = prefix
            first = n - 1
        } else {
            pixels = Data(count: width * height)
        }
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = grayContext(buffer.baseAddress, width: width, height: height) else { return }
            for stroke in brush.strokes[first...] { draw(stroke, into: ctx, width: width, height: height) }
        }
        cache.set(key, pixels)
        return makeImage(pixels, width: width, height: height)
    }

    // MARK: Drawing

    /// Draws one stroke into `acc` (CG y-up coordinates, raster pixels).
    static func draw(_ stroke: BrushStroke, into acc: CGContext, width: Int, height: Int) {
        guard !stroke.points.isEmpty else { return }
        let flow = CGFloat(min(max(stroke.flow, 0), 100)) / 100
        guard flow > 0 else { return }
        let w = CGFloat(width), h = CGFloat(height)
        let outer = max(CGFloat(stroke.radius) * w, 0.5)
        let inner = outer * (1 - CGFloat(min(max(stroke.feather, 0), 100)) / 100)
        let pts = stroke.points.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }

        var box = CGRect.null
        for p in pts { box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        box = box.insetBy(dx: -outer - 2, dy: -outer - 2).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return }

        // Stroke layer (only the stroke's bounding box).
        let bw = Int(box.width), bh = Int(box.height)
        var layerPixels = Data(count: bw * bh)
        let layerImage: CGImage? = layerPixels.withUnsafeMutableBytes { buffer in
            guard let layer = grayContext(buffer.baseAddress, width: bw, height: bh) else { return nil }
            layer.translateBy(x: -box.minX, y: -box.minY)
            let path = CGMutablePath()
            if pts.count > 1 { path.addLines(between: pts) }
            layer.setLineCap(.round)
            layer.setLineJoin(.round)
            func pass(radius r: CGFloat, value v: CGFloat) {
                guard r > 0.05 else { return }
                if pts.count == 1 {
                    layer.setFillColor(gray: v, alpha: 1)
                    layer.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
                } else {
                    layer.setStrokeColor(gray: v, alpha: 1)
                    layer.setLineWidth(2 * r)
                    layer.addPath(path)
                    layer.strokePath()
                }
            }
            // Widest (darkest) first; each narrower pass overwrites the inside → max falloff.
            let steps = outer - inner > 0.5 ? min(max(Int((outer - inner).rounded(.up)), 2), 40) : 0
            for i in 0..<steps {
                let t = (CGFloat(i) + 0.5) / CGFloat(steps)
                pass(radius: outer - (outer - inner) * CGFloat(i) / CGFloat(steps), value: t * t * (3 - 2 * t))
            }
            pass(radius: steps == 0 ? outer : inner, value: 1)
            return layer.makeImage()
        }
        guard let layerImage else { return }

        acc.saveGState()
        acc.clip(to: box, mask: layerImage)
        acc.setFillColor(gray: stroke.isEraser ? 0 : 1, alpha: flow)
        acc.fill(box)
        acc.restoreGState()
    }

    private static let gray = CGColorSpaceCreateDeviceGray()

    private static func grayContext(_ data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        guard let data else { return nil }
        let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.setShouldAntialias(true)
        return ctx
    }

    private static func makeImage(_ pixels: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: gray, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Cache

    struct Key: Hashable {
        let id: UUID
        let hash: Int
        let width: Int
        let height: Int
    }

    /// `result[k]` = hash of `strokes[0..<k]`.
    static func prefixHashes(_ strokes: [BrushStroke]) -> [Int] {
        var result = [0]
        result.reserveCapacity(strokes.count + 1)
        var running = 0
        for s in strokes {
            var h = Hasher()
            h.combine(running)
            h.combine(s.radius); h.combine(s.feather); h.combine(s.flow); h.combine(s.isEraser)
            h.combine(s.points.count)
            for p in s.points { h.combine(p.x); h.combine(p.y) }
            running = h.finalize()
            result.append(running)
        }
        return result
    }

    /// Small LRU of raster bitmaps, bounded by total bytes.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Key: Data] = [:]
        private var order: [Key] = []
        private var bytes = 0
        let maxBytes: Int

        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func get(_ key: Key) -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let d = entries[key] else { return nil }
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
            return d
        }

        func set(_ key: Key, _ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if let old = entries.updateValue(data, forKey: key) {
                bytes -= old.count
                order.removeAll { $0 == key }
            }
            order.append(key)
            bytes += data.count
            while bytes > maxBytes, order.count > 1 {
                let k = order.removeFirst()
                bytes -= entries.removeValue(forKey: k)?.count ?? 0
            }
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll(); order.removeAll(); bytes = 0
        }
    }

    static let cache = Cache(maxBytes: 96 << 20)
}

