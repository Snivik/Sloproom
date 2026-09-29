// Renders the Sloproom app icon: "Sr" in a Lightroom-style rounded tile on an orange background.
// usage: make_icon <out.png> <variant: light|dark>
import AppKit
import CoreText

let args = CommandLine.arguments
let out = args[1], variant = args.count > 2 ? args[2] : "light"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
// macOS icon grid: 824pt tile centred in 1024 with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0x000000, 0.35))
ctx.addPath(path); ctx.setFillColor(c(0xD97757)); ctx.fillPath()
ctx.restoreGState()
// Orange gradient fill
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(0xE8875F), c(0xC85A33)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()
// Lightroom-style inner border
let ink = variant == "dark" ? c(0x2B1206) : c(0xFFF3EA)
let inset = tile.insetBy(dx: 34, dy: 34)
let innerPath = CGPath(roundedRect: inset, cornerWidth: radius - 34, cornerHeight: radius - 34, transform: nil)
ctx.addPath(innerPath); ctx.setStrokeColor(ink); ctx.setLineWidth(18); ctx.strokePath()
// Letters "Sr"
let font = CTFontCreateWithName("SFPro-Semibold" as CFString, 430, nil)
let base = NSFont.systemFont(ofSize: 430, weight: .semibold)
let attr = NSAttributedString(string: "Sr", attributes: [.font: base as Any, .foregroundColor: NSColor(cgColor: ink)!, .kern: -8])
_ = font
let line = CTLineCreateWithAttributedString(attr)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: tile.midX - bounds.width / 2 - bounds.minX, y: tile.midY - bounds.height / 2 - bounds.minY - 6)
CTLineDraw(line, ctx)
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
