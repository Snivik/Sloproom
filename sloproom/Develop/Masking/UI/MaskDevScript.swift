//
//  MaskDevScript.swift
//  sloproom
//
//  DevScript commands for headless checks of the mask tool (see App/DevTools.swift):
//    mask linear|radial [cx cy]|brush   add a demo mask (with adjustments) and select it
//    maskoverlay on|off         toggle the red coverage overlay
//    maskcreate linear|radial|brush   "Create New Mask" (pending creation state)
//

#if DEBUG
import Foundation

enum MaskDevScript {
    static let commands: Set<String> = ["mask", "maskoverlay", "maskcreate"]

    static func run(_ command: String, _ arg: String, session: DevelopSession?) {
        guard let session else { return }
        switch command {
        case "mask":
            var id: UUID
            let words = arg.split(separator: " ").map(String.init)   // "radial [cx cy]"
            switch words.first ?? "" {
            case "radial":
                var r = RadialGradientMask()
                r.radiusX = 0.3; r.radiusY = 0.35; r.rotation = 15; r.feather = 60
                if words.count == 3, let x = Double(words[1]), let y = Double(words[2]) {
                    r.center = NormPoint(x: x, y: y); r.radiusX = 0.12; r.radiusY = 0.2; r.feather = 20
                }
                id = session.addMask(.radial(r))
                session.updateMask(id) { $0.adjustments.exposure = 1; $0.inverted = false }
            case "brush":
                var stroke = BrushStroke()
                stroke.radius = 0.04
                for i in 0...40 {
                    let t = Double(i) / 40
                    MaskEditing.append(NormPoint(x: 0.2 + 0.6 * t, y: 0.6 + 0.05 * sin(t * 2 * .pi)), to: &stroke, aspect: 1.5)
                }
                var eraser = BrushStroke()
                eraser.radius = 0.02; eraser.isEraser = true
                eraser.points = [NormPoint(x: 0.5, y: 0.5), NormPoint(x: 0.5, y: 0.7)]
                var b = BrushMask(); b.strokes = [stroke, eraser]
                id = session.addMask(.brush(b))
                session.updateMask(id) { $0.adjustments.exposure = 2 }
            default:
                id = session.addMask(.linear(LinearGradientMask(start: NormPoint(x: 0.5, y: 0), end: NormPoint(x: 0.5, y: 0.4))))
                session.updateMask(id) { $0.adjustments.exposure = -1.5 }
            }
        case "maskoverlay":
            MaskToolState.shared.showOverlay = arg != "off"
        case "maskcreate":
            session.beginCreatingMask(MaskKind(rawValue: arg) ?? .linear)
        default:
            break
        }
    }
}
#endif
