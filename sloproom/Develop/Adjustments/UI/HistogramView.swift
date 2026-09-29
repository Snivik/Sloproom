//
//  HistogramView.swift
//  sloproom
//
//  Top-of-inspector RGB histogram of the image on screen (session.histogram), with shadow /
//  highlight clipping indicators and a Before/After badge.
//

import SwiftUI

struct HistogramView: View {
    let session: DevelopSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.85))
            if let h = session.histogram {
                Canvas { ctx, size in
                    ctx.blendMode = .plusLighter
                    for (bins, color) in [(h.red, Color.red), (h.green, Color.green), (h.blue, Color.blue)] {
                        ctx.fill(Self.path(bins, in: size), with: .color(color.opacity(0.55)))
                    }
                    ctx.blendMode = .normal
                    ctx.stroke(Self.path(h.luma, in: size, closed: false), with: .color(.white.opacity(0.35)), lineWidth: 0.7)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                clip(h.shadowClip, alignment: .topLeading)
                clip(h.highlightClip, alignment: .topTrailing)
            }
            if session.showBefore {
                Text("Before").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(height: 84)
        .help("Histogram")
    }

    /// Small triangle that lights up when more than 0.5 % of pixels clip.
    private func clip(_ fraction: Float, alignment: Alignment) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 7))
            .rotationEffect(.degrees(alignment == .topLeading ? -90 : 90))
            .foregroundStyle(fraction > 0.005 ? Color.white : Color.white.opacity(0.25))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .help(String(format: "%.1f %% clipped", fraction * 100))
    }

    private static func path(_ bins: [Float], in size: CGSize, closed: Bool = true) -> Path {
        var p = Path()
        let n = bins.count
        guard n > 1 else { return p }
        let dx = size.width / CGFloat(n - 1)
        func y(_ v: Float) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), 1)) * 0.95) }
        if closed { p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: 0, y: y(bins[0]))) }
        else { p.move(to: CGPoint(x: 0, y: y(bins[0]))) }
        for i in 1..<n { p.addLine(to: CGPoint(x: CGFloat(i) * dx, y: y(bins[i]))) }
        if closed { p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath() }
        return p
    }
}
