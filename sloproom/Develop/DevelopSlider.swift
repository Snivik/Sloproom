//
//  DevelopSlider.swift
//  sloproom
//
//  The slider every Develop panel uses (Lightroom-style):
//  - title, editable value field (type a number + Return; Esc cancels),
//  - thin track (optionally a color gradient, e.g. Temp/Tint/Color Mixer) with a tick at the
//    default value; drag anywhere (relative), click away from the thumb to jump,
//  - ⌥-drag = 10× finer, double-click the title or the track to reset,
//  - optional logarithmic scale (Kelvin), snapping `step`.
//  Calls `onEditingChanged(true)` when a drag starts and `(false)` when it ends / after a reset
//  or typed value (panels pass `session.commitUndoGroup()` so one drag = one undo step).
//

import AppKit
import SwiftUI

struct DevelopSlider: View {
    enum Scale { case linear, logarithmic }

    enum Format {
        /// "12"
        case integer
        /// "+12" / "-12" / "0"
        case signedInteger
        /// "+1.25" with the given fraction digits
        case signedDecimal(Int)
        /// "5500 K"
        case kelvin
        case custom((Double) -> String)

        func string(_ v: Double) -> String {
            switch self {
            case .integer: return String(format: "%.0f", v)
            case .signedInteger: return v.rounded() == 0 ? "0" : String(format: "%+.0f", v)
            case .signedDecimal(let digits): return abs(v) < 0.5 * pow(10, -Double(digits)) ? String(format: "%.\(digits)f", 0.0) : String(format: "%+.\(digits)f", v)
            case .kelvin: return String(format: "%.0f K", v)
            case .custom(let f): return f(v)
            }
        }
    }

    enum Track {
        case plain
        /// Left-to-right colors along the track.
        case gradient([Color])
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var scale: Scale = .linear
    var format: Format = .signedInteger
    /// Snap to multiples of `step` (nil = continuous).
    var step: Double? = nil
    var track: Track = .plain
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var text = ""
    @FocusState private var fieldFocused: Bool
    /// Drag state: slider position (0...1) and last x while dragging.
    @State private var dragPosition: Double?
    @State private var dragLastX: CGFloat = 0

    private let thumbSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { reset() }
                    .help("Double-click to reset")
                Spacer(minLength: 4)
                valueField
            }
            .font(.callout)
            trackView
                .frame(height: 14)
        }
        .padding(.vertical, 1)
        .opacity(isEnabled ? 1 : 0.45)
    }

    // MARK: - Value field

    private var valueField: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .foregroundStyle(isAtDefault && !fieldFocused ? .secondary : .primary)
            .frame(width: 58)
            .focused($fieldFocused)
            .onSubmit { commitText(); fieldFocused = false }
            .onExitCommand { text = format.string(value); fieldFocused = false }
            .onChange(of: fieldFocused) { _, focused in if !focused { commitText() } }
            .onChange(of: value) { _, v in if !fieldFocused { text = format.string(v) } }
            .onAppear { text = format.string(value) }
    }

    private var isAtDefault: Bool { abs(value - defaultValue) < 1e-9 }

    private func commitText() {
        let cleaned = text.filter { "0123456789.,-+".contains($0) }.replacingOccurrences(of: ",", with: ".")
        if let v = Double(cleaned), v.isFinite {
            let clamped = snap(v).clamped(to: range)
            if clamped != value { value = clamped; onEditingChanged(false) }
        }
        text = format.string(value)
    }

    // MARK: - Track

    private var trackView: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - thumbSize)
            let t = dragPosition ?? position(of: value)
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                trackFill
                    .frame(width: geo.size.width - 2, height: 4)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .position(x: geo.size.width / 2, y: midY)
                // Default tick.
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1, height: 8)
                    .position(x: thumbSize / 2 + position(of: defaultValue) * usable, y: midY)
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: thumbSize / 2 + t * usable, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(usable: usable))
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
    }

    @ViewBuilder
    private var trackFill: some View {
        switch track {
        case .plain: Color.primary.opacity(0.18)
        case .gradient(let colors): LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
        }
    }

    private func dragGesture(usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let fine = NSEvent.modifierFlags.contains(.option)
                if dragPosition == nil {
                    // Press: on the thumb = grab it; elsewhere = jump there.
                    let current = position(of: value)
                    let thumbX = thumbSize / 2 + current * usable
                    dragPosition = abs(g.startLocation.x - thumbX) <= thumbSize
                        ? current
                        : Double(((g.startLocation.x - thumbSize / 2) / usable).clamped(to: 0...1))
                    dragLastX = g.startLocation.x
                    onEditingChanged(true)
                }
                let dx = g.location.x - dragLastX
                dragLastX = g.location.x
                let t = ((dragPosition ?? 0) + Double(dx / usable) * (fine ? 0.1 : 1)).clamped(to: 0...1)
                dragPosition = t
                let v = snap(valueAt(t)).clamped(to: range)
                if v != value { value = v }
            }
            .onEnded { _ in
                dragPosition = nil
                onEditingChanged(false)
            }
    }

    private func reset() {
        dragPosition = nil
        value = defaultValue
        onEditingChanged(false)
    }

    private func snap(_ v: Double) -> Double {
        guard let step, step > 0 else { return v }
        return (v / step).rounded() * step
    }

    /// Value -> 0...1 track position (linear or logarithmic).
    private func position(of v: Double) -> Double {
        let v = v.clamped(to: range)
        switch scale {
        case .linear:
            return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        case .logarithmic:
            return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
    }

    private func valueAt(_ t: Double) -> Double {
        switch scale {
        case .linear: return range.lowerBound + t * (range.upperBound - range.lowerBound)
        case .logarithmic: return range.lowerBound * pow(range.upperBound / range.lowerBound, t)
        }
    }
}
