//
//  DevelopSession+Crop.swift
//  sloproom
//
//  Crop & rotate actions used by CropPanel, CropOverlayView and the crop key shortcuts.
//  Everything edits `session.settings.geometry`; the crop is always kept inside the rotated
//  content (CropMath). Each action is one undo step.
//
//  Crop tool session: entering the tool (any way: R, panel button, tool picker) snapshots the
//  geometry (`CropToolState.startGeometry`, via DevelopSession.activeTool); Enter / Done / R
//  keep the changes, Esc restores the snapshot.
//

import Foundation
import CoreGraphics
import Observation
import SwiftUI

/// Crop overlay grid shown while dragging (O cycles).
enum CropGridMode: String, CaseIterable {
    case thirds, grid, none

    var next: CropGridMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Aspect choice shown in the panel's picker.
enum CropAspectChoice: Hashable {
    /// The photo's own ratio (of the rotated frame), locked.
    case original
    /// Free: no ratio lock.
    case custom
    case preset(Int64)
}

/// Per-session crop tool UI state. Owned by DevelopSession (`session.cropTool`).
@Observable
final class CropToolState {
    /// Geometry when the crop tool was entered (Esc restores it).
    var startGeometry: Geometry?
    /// A drag / straighten interaction is in progress (shows the grid).
    var isInteracting = false
    /// True while rotating (finer grid for aligning horizons).
    var isRotating = false
    /// Crop and angle at the start of the current straighten interaction (so the crop can grow
    /// back when the angle returns).
    var straightenBase: (crop: NormRect, angle: Double)?
    /// Presets as last loaded from the catalog (for ratio lookups by id).
    var presets: [CropPreset] = []

    var gridMode: CropGridMode = CropGridMode(rawValue: UserDefaults.standard.string(forKey: "crop.gridMode") ?? "") ?? .thirds {
        didSet { UserDefaults.standard.set(gridMode.rawValue, forKey: "crop.gridMode") }
    }
}

extension DevelopSession {
    var isCropping: Bool { activeTool == .crop }

    /// Crop math for the current photo (frame pixels at full resolution).
    func cropMath(angle: Double? = nil) -> CropMath {
        CropMath(sourceSize: orientedSize, geometry: settings.geometry, angle: angle)
    }

    /// Current crop in full-res frame pixels.
    var cropPixelRect: CGRect { cropMath().pixelRect(settings.geometry.crop) }

    /// Current crop aspect ratio (width / height, in pixels).
    var cropAspect: CGFloat {
        let r = cropPixelRect
        return r.height > 0 ? r.width / r.height : 1
    }

    /// Frame aspect ratio (after quarter turns).
    var frameAspect: CGFloat {
        let f = cropMath().frameSize
        return f.height > 0 ? f.width / f.height : 1
    }

    // MARK: Tool

    func toggleCropTool() {
        activeTool = isCropping ? .none : .crop
    }

    /// Enter / Done: keep the changes and leave the tool.
    func commitCrop() {
        guard isCropping else { return }
        commitUndoGroup()
        activeTool = .none
    }

    /// Esc: restore the geometry from when the tool was entered and leave the tool.
    func cancelCrop() {
        guard isCropping else { return }
        if let start = cropTool.startGeometry, start != settings.geometry {
            geometryStep { $0 = start }
        }
        activeTool = .none
    }

    // MARK: Actions (each one undo step)

    private func geometryStep(_ change: (inout Geometry) -> Void) {
        commitUndoGroup()
        change(&settings.geometry)
        commitUndoGroup()
    }

    func rotateQuarter(clockwise: Bool) {
        geometryStep { $0 = $0.rotatedQuarter(clockwise: clockwise) }
    }

    func flipHorizontally() {
        geometryStep { $0 = $0.flippedHorizontally() }
    }

    /// Resets crop and straighten (keeps quarter turns, flip and the aspect lock).
    func resetCrop() {
        geometryStep {
            $0.straightenAngle = 0
            $0.crop = .full
            $0.cropPresetID = nil
        }
    }

    /// Applies `ratio` (width / height): max-sized inside the (straightened) image, as close to
    /// the current crop's center as possible.
    func applyCropAspect(_ ratio: CGFloat, presetID: Int64?, lock: Bool = true) {
        guard ratio > 0 else { return }
        let math = cropMath()
        let current = math.pixelRect(settings.geometry.crop)
        let rect = math.maxRect(aspect: ratio, near: CGPoint(x: current.midX, y: current.midY))
        geometryStep {
            $0.crop = math.normRect(rect)
            $0.cropPresetID = presetID
            $0.aspectLocked = lock
        }
    }

    /// Picker selection.
    var cropAspectChoice: CropAspectChoice {
        let g = settings.geometry
        if let id = g.cropPresetID, cropTool.presets.contains(where: { $0.id == id }) { return .preset(id) }
        guard g.aspectLocked else { return .custom }
        let a = cropAspect, f = frameAspect
        return abs(a / f - 1) < 0.005 || abs(a * f - 1) < 0.005 ? .original : .custom
    }

    func selectCropAspect(_ choice: CropAspectChoice) {
        switch choice {
        case .original:
            applyCropAspect(frameAspect, presetID: nil)
        case .custom:
            geometryStep { $0.aspectLocked = false; $0.cropPresetID = nil }
        case .preset(let id):
            guard let p = cropTool.presets.first(where: { $0.id == id }), p.ratioW > 0, p.ratioH > 0 else { return }
            applyCropAspect(CGFloat(p.ratio), presetID: id)
        }
    }

    func setCropAspectLocked(_ locked: Bool) {
        geometryStep {
            $0.aspectLocked = locked
            if !locked { $0.cropPresetID = nil }
        }
    }

    /// X: portrait <-> landscape for the current ratio (max-sized, around the current center).
    func swapCropOrientation() {
        let a = cropAspect
        guard abs(a - 1) > 1e-6 else { return }
        let g = settings.geometry
        applyCropAspect(1 / a, presetID: g.cropPresetID, lock: g.aspectLocked)
    }

    // MARK: Straighten

    /// Call when a straighten interaction (slider drag, rotate drag) begins.
    func beginStraighten() {
        cropTool.straightenBase = (settings.geometry.crop, settings.geometry.straightenAngle)
    }

    /// Call when it ends (one undo step per interaction).
    func endStraighten() {
        cropTool.straightenBase = nil
        commitUndoGroup()
    }

    /// Sets the straighten angle and constrains the crop to the rotated image. Within one
    /// interaction the crop is derived from the crop at its start: a crop that was maximal for its
    /// ratio stays maximal (it grows back when the angle returns), others shrink about their center.
    func setStraighten(_ angle: Double) {
        let angle = min(max(angle, Geometry.straightenRange.lowerBound), Geometry.straightenRange.upperBound)
        let base = cropTool.straightenBase ?? (settings.geometry.crop, settings.geometry.straightenAngle)
        let baseMath = cropMath(angle: base.angle)
        let baseRect = baseMath.pixelRect(base.crop)
        let newMath = cropMath(angle: angle)
        let center = CGPoint(x: baseRect.midX, y: baseRect.midY)
        let wasMaximal = baseMath.maxScale(center: center, size: baseRect.size) < 1.002
        let rect: CGRect
        if wasMaximal, baseRect.height > 0 {
            rect = newMath.maxRect(aspect: baseRect.width / baseRect.height, near: center)
        } else {
            rect = newMath.fitted(baseRect)
        }
        var g = settings.geometry
        g.straightenAngle = angle
        g.crop = newMath.normRect(rect)
        settings.geometry = g
    }

    /// Straighten slider binding (one undo step per drag).
    var straightenBinding: Binding<Double> {
        Binding { self.settings.geometry.straightenAngle } set: { self.setStraighten($0) }
    }
}
