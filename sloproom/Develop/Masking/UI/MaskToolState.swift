//
//  MaskToolState.swift
//  sloproom
//
//  UI state of the mask tool shared by MaskPanel and MaskOverlayView (one Develop view at a
//  time, so a single shared instance). Brush settings persist in UserDefaults.
//

import CoreGraphics
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

    /// Brush size 1...100, a SCREEN size (Lightroom): the cursor radius is
    /// `brushSize × screenPointsPerSize` view points at any zoom. Each stroke stores its radius
    /// in image units computed from the zoom at paint time (`brushRadius(in:)`), so painting
    /// zoomed in paints finer strokes. Stored strokes are image-normalized and unaffected.
    var brushSize: Double { didSet { save(brushSize, "size") } }
    /// 0...100
    var brushFeather: Double { didSet { save(brushFeather, "feather") } }
    /// 0...100
    var brushFlow: Double { didSet { save(brushFlow, "flow") } }

    static let sizeRange: ClosedRange<Double> = 1...100

    /// View points of cursor radius per unit of `brushSize` (16 → 40 pt, about the old size at Fit).
    static let screenPointsPerSize: CGFloat = 2.5

    /// Cursor radius in view points (constant on screen).
    var brushScreenRadius: CGFloat { CGFloat(brushSize) * Self.screenPointsPerSize }

    /// Radius for a new stroke as a fraction of the oriented image width (`BrushStroke.radius`)
    /// at the current zoom: the screen radius converted through the canvas geometry.
    func brushRadius(in geometry: CanvasGeometry) -> Double {
        geometry.sourceWidthFraction(fromViewLength: brushScreenRadius)
    }

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
