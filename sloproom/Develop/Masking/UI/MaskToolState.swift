//
//  MaskToolState.swift
//  sloproom
//
//  UI state of the mask tool shared by MaskPanel and MaskOverlayView (one Develop view at a
//  time, so a single shared instance). Brush settings persist in UserDefaults.
//

import Foundation
import Observation

@Observable
final class MaskToolState {
    static let shared = MaskToolState()

    /// Shape the next drag on the canvas creates (nil = edit the selected mask).
    var pendingKind: MaskKind?
    /// Red overlay of the selected mask's coverage (O).
    var showOverlay = false
    /// Paint eraser strokes (also while ⌥ is held).
    var eraseMode = false

    /// Brush size 1...100 (radius = size / 400 of the image width).
    var brushSize: Double { didSet { save(brushSize, "size") } }
    /// 0...100
    var brushFeather: Double { didSet { save(brushFeather, "feather") } }
    /// 0...100
    var brushFlow: Double { didSet { save(brushFlow, "flow") } }

    static let sizeRange: ClosedRange<Double> = 1...100

    /// Brush radius as a fraction of the oriented image width (`BrushStroke.radius`).
    var brushRadius: Double { brushSize / 400 }

    /// `[` / `]`
    func stepBrushSize(up: Bool) {
        brushSize = min(max(brushSize * (up ? 1.2 : 1 / 1.2), Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    private init() {
        let d = UserDefaults.standard
        brushSize = d.object(forKey: "develop.mask.brush.size") as? Double ?? 16
        brushFeather = d.object(forKey: "develop.mask.brush.feather") as? Double ?? 50
        brushFlow = d.object(forKey: "develop.mask.brush.flow") as? Double ?? 100
    }

    private func save(_ value: Double, _ key: String) {
        UserDefaults.standard.set(value, forKey: "develop.mask.brush.\(key)")
    }
}
