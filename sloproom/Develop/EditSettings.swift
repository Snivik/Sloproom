//
//  EditSettings.swift
//  sloproom
//
//  The complete, non-destructive edit of one photo. Stored as JSON in `photos.edit_settings`.
//
//  Rules:
//  - Every field has a default that means "no change"; `EditSettings()` renders the original.
//  - Decoding tolerates missing keys (falls back to defaults), so adding fields never breaks
//    old JSON. When you add a field: give it a default AND decode it with `c.decode(.key, default:)`.
//  - Never rename/remove a key or change its units; add a new one instead.
//
//  Coordinate conventions:
//  - `NormPoint` / `NormRect` are normalized 0...1 with the ORIGIN AT THE TOP-LEFT, y pointing down.
//  - Masks live in ORIENTED, UNCROPPED image space: EXIF orientation applied, but before the
//    user's quarter turns / flip / straighten / crop (masks are rendered before geometry).
//  - `Geometry.crop` lives in the space after quarter turns + flip, i.e. normalized to the rotated
//    image frame; straighten rotates the content inside that frame about its center
//    (see GeometryMath).
//

import Foundation
import CoreGraphics

// MARK: - Root

nonisolated struct EditSettings: Codable, Equatable, Sendable {
    /// JSON schema version. Bump only for incompatible semantic changes.
    var version: Int = 1
    var whiteBalance = WhiteBalance()
    var tone = Tone()
    var presence = Presence()
    var colorMixer = ColorMixer()
    var effects = Effects()
    var geometry = Geometry()
    /// Local adjustments, applied in array order.
    var masks: [Mask] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decode(.version, default: 1)
        whiteBalance = c.decode(.whiteBalance, default: WhiteBalance())
        tone = c.decode(.tone, default: Tone())
        presence = c.decode(.presence, default: Presence())
        colorMixer = c.decode(.colorMixer, default: ColorMixer())
        effects = c.decode(.effects, default: Effects())
        geometry = c.decode(.geometry, default: Geometry())
        masks = c.decode(.masks, default: [])
    }

    /// True when rendering these settings equals rendering the original.
    var isDefault: Bool {
        whiteBalance.isDefault && tone.isDefault && presence.isDefault && colorMixer.isDefault
            && effects.isDefault && geometry.isDefault && masks.allSatisfy { !$0.isEnabled || $0.adjustments.isDefault }
    }

    /// True only for untouched settings (`EditSettings()`): no masks (not even hidden / empty
    /// ones), default geometry incl. preset / aspect lock, etc. Persistence drops ONLY these
    /// (stores NULL); `isDefault` is about rendering and would lose e.g. a freshly created mask.
    var isEmpty: Bool { self == EditSettings() }

    // MARK: JSON

    static func fromJSON(_ json: String?) -> EditSettings? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditSettings.self, from: data)
    }

    func jsonString() -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - White balance

nonisolated struct WhiteBalance: Codable, Equatable, Sendable {
    nonisolated enum Mode: String, Codable, Sendable, CaseIterable {
        /// Use the camera's as-shot white balance (temperature/tint ignored).
        case asShot
        /// Use `temperature` / `tint`.
        case custom
    }
    static let temperatureRange: ClosedRange<Double> = 2000...50000
    static let tintRange: ClosedRange<Double> = -150...150

    var mode: Mode = .asShot
    /// Kelvin. Higher = warmer result (like Lightroom: you tell it the light was bluer).
    var temperature: Double = 5500
    /// Green (-) ... magenta (+).
    var tint: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.decode(.mode, default: .asShot)
        temperature = c.decode(.temperature, default: 5500)
        tint = c.decode(.tint, default: 0)
    }
    var isDefault: Bool { mode == .asShot }
}

// MARK: - Tone

nonisolated struct Tone: Codable, Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -5...5
    static let range: ClosedRange<Double> = -100...100

    /// EV stops.
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = c.decode(.exposure, default: 0)
        contrast = c.decode(.contrast, default: 0)
        highlights = c.decode(.highlights, default: 0)
        shadows = c.decode(.shadows, default: 0)
        whites = c.decode(.whites, default: 0)
        blacks = c.decode(.blacks, default: 0)
    }
    var isDefault: Bool { self == Tone() }
}

// MARK: - Presence

nonisolated struct Presence: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -100...100

    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        texture = c.decode(.texture, default: 0)
        clarity = c.decode(.clarity, default: 0)
        dehaze = c.decode(.dehaze, default: 0)
        vibrance = c.decode(.vibrance, default: 0)
        saturation = c.decode(.saturation, default: 0)
    }
    var isDefault: Bool { self == Presence() }
}

// MARK: - Color mixer (HSL)

nonisolated enum ColorBand: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable, Hashable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
}

nonisolated struct HSLAdjustment: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -100...100

    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    init() {}
    init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = c.decode(.hue, default: 0)
        saturation = c.decode(.saturation, default: 0)
        luminance = c.decode(.luminance, default: 0)
    }
    var isDefault: Bool { self == HSLAdjustment() }
}

nonisolated struct ColorMixer: Codable, Equatable, Sendable {
    /// Encoded as a JSON object keyed by band name (`{"red": {...}}`). Missing band = no change.
    /// Always mutate through the subscript so default entries are dropped (keeps Equatable sane).
    private(set) var bands: [ColorBand: HSLAdjustment] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded: [ColorBand: HSLAdjustment] = c.decode(.bands, default: [:])
        bands = decoded.filter { !$0.value.isDefault }
    }

    subscript(band: ColorBand) -> HSLAdjustment {
        get { bands[band] ?? HSLAdjustment() }
        set { bands[band] = newValue.isDefault ? nil : newValue }
    }
    var isDefault: Bool { bands.values.allSatisfy(\.isDefault) }
}

// MARK: - Effects

nonisolated struct Effects: Codable, Equatable, Sendable {
    /// Post-crop vignette, -100 (dark) ... 100 (light).
    var vignetteAmount: Double = 0
    /// 0...100
    var vignetteMidpoint: Double = 50
    /// -100...100
    var vignetteRoundness: Double = 0
    /// 0...100
    var vignetteFeather: Double = 50
    /// 0...100
    var grainAmount: Double = 0
    /// 0...100
    var grainSize: Double = 25
    /// 0...100
    var grainRoughness: Double = 50

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vignetteAmount = c.decode(.vignetteAmount, default: 0)
        vignetteMidpoint = c.decode(.vignetteMidpoint, default: 50)
        vignetteRoundness = c.decode(.vignetteRoundness, default: 0)
        vignetteFeather = c.decode(.vignetteFeather, default: 50)
        grainAmount = c.decode(.grainAmount, default: 0)
        grainSize = c.decode(.grainSize, default: 25)
        grainRoughness = c.decode(.grainRoughness, default: 50)
    }
    /// Only the amounts matter: with zero amount the other parameters have no effect.
    var isDefault: Bool { vignetteAmount == 0 && grainAmount == 0 }
}

// MARK: - Geometry

/// Normalized point, 0...1, origin TOP-LEFT, y down.
nonisolated struct NormPoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Normalized rect, 0...1, origin TOP-LEFT, y down.
nonisolated struct NormRect: Codable, Equatable, Hashable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    static let full = NormRect()
    init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    init(_ r: CGRect) { x = Double(r.minX); y = Double(r.minY); width = Double(r.width); height = Double(r.height) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isFull: Bool { self == .full }
}

nonisolated struct Geometry: Codable, Equatable, Sendable {
    static let straightenRange: ClosedRange<Double> = -45...45

    /// Clockwise 90° turns, 0...3. Applied first (after EXIF orientation).
    var quarterTurns: Int = 0
    /// Mirror horizontally, applied AFTER quarter turns (mirrors what the user sees).
    var flipHorizontal: Bool = false
    /// Degrees, clockwise positive, rotation of the content about the frame center.
    var straightenAngle: Double = 0
    /// Crop in the rotated (quarter turns + flip) frame, normalized, top-left origin.
    var crop: NormRect = .full
    /// Crop preset chosen in the UI (nil = free / original). Informational for the crop tool.
    var cropPresetID: Int64? = nil
    var aspectLocked: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = c.decode(.quarterTurns, default: 0)
        flipHorizontal = c.decode(.flipHorizontal, default: false)
        straightenAngle = c.decode(.straightenAngle, default: 0)
        crop = c.decode(.crop, default: .full)
        cropPresetID = c.decode(.cropPresetID, default: nil)
        aspectLocked = c.decode(.aspectLocked, default: false)
    }
    /// Normalized quarter turns (always 0...3).
    var normalizedQuarterTurns: Int { ((quarterTurns % 4) + 4) % 4 }
    var isDefault: Bool {
        normalizedQuarterTurns == 0 && !flipHorizontal && straightenAngle == 0 && crop.isFull
    }
}

// MARK: - Masks

nonisolated struct Mask: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String = "Mask"
    var isEnabled: Bool = true
    /// Invert the mask (adjust everything outside the shape).
    var inverted: Bool = false
    var shape: MaskShape
    var adjustments = LocalAdjustments()

    init(name: String = "Mask", shape: MaskShape, adjustments: LocalAdjustments = LocalAdjustments()) {
        self.name = name; self.shape = shape; self.adjustments = adjustments
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "Mask")
        isEnabled = c.decode(.isEnabled, default: true)
        inverted = c.decode(.inverted, default: false)
        shape = try c.decode(MaskShape.self, forKey: .shape)
        adjustments = c.decode(.adjustments, default: LocalAdjustments())
    }
}

/// Encoded as `{"kind": "linear" | "radial" | "brush", "<kind>": {...}}`.
nonisolated enum MaskShape: Codable, Equatable, Sendable {
    case linear(LinearGradientMask)
    case radial(RadialGradientMask)
    case brush(BrushMask)

    private enum CodingKeys: String, CodingKey { case kind, linear, radial, brush }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "linear": self = .linear(try c.decode(LinearGradientMask.self, forKey: .linear))
        case "radial": self = .radial(try c.decode(RadialGradientMask.self, forKey: .radial))
        case "brush": self = .brush(try c.decode(BrushMask.self, forKey: .brush))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown mask kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear(let m): try c.encode("linear", forKey: .kind); try c.encode(m, forKey: .linear)
        case .radial(let m): try c.encode("radial", forKey: .kind); try c.encode(m, forKey: .radial)
        case .brush(let m): try c.encode("brush", forKey: .kind); try c.encode(m, forKey: .brush)
        }
    }
}

/// Full effect at `start`, fading linearly to none at `end` (and beyond).
nonisolated struct LinearGradientMask: Codable, Equatable, Sendable {
    var start = NormPoint(x: 0.5, y: 0.25)
    var end = NormPoint(x: 0.5, y: 0.75)

    init() {}
    init(start: NormPoint, end: NormPoint) { self.start = start; self.end = end }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = c.decode(.start, default: NormPoint(x: 0.5, y: 0.25))
        end = c.decode(.end, default: NormPoint(x: 0.5, y: 0.75))
    }
}

/// Ellipse; full effect inside, feathered edge. Radii are normalized to image width (radiusX)
/// and image height (radiusY) of the oriented uncropped image.
nonisolated struct RadialGradientMask: Codable, Equatable, Sendable {
    var center = NormPoint(x: 0.5, y: 0.5)
    var radiusX: Double = 0.25
    var radiusY: Double = 0.25
    /// Degrees, clockwise.
    var rotation: Double = 0
    /// 0...100
    var feather: Double = 50

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = c.decode(.center, default: NormPoint(x: 0.5, y: 0.5))
        radiusX = c.decode(.radiusX, default: 0.25)
        radiusY = c.decode(.radiusY, default: 0.25)
        rotation = c.decode(.rotation, default: 0)
        feather = c.decode(.feather, default: 50)
    }
}

nonisolated struct BrushStroke: Codable, Equatable, Sendable {
    var points: [NormPoint] = []
    /// Brush radius as a fraction of the oriented uncropped image WIDTH.
    var radius: Double = 0.02
    /// 0...100
    var feather: Double = 50
    /// 0...100
    var flow: Double = 100
    /// Eraser strokes subtract from the mask.
    var isEraser: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = c.decode(.points, default: [])
        radius = c.decode(.radius, default: 0.02)
        feather = c.decode(.feather, default: 50)
        flow = c.decode(.flow, default: 100)
        isEraser = c.decode(.isEraser, default: false)
    }
}

nonisolated struct BrushMask: Codable, Equatable, Sendable {
    var strokes: [BrushStroke] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = c.decode(.strokes, default: [])
    }
}

/// Adjustments applied inside a mask. All -100...100 except `exposure` (-4...4 EV).
nonisolated struct LocalAdjustments: Codable, Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -4...4
    static let range: ClosedRange<Double> = -100...100

    var temperature: Double = 0
    var tint: Double = 0
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var saturation: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = c.decode(.temperature, default: 0)
        tint = c.decode(.tint, default: 0)
        exposure = c.decode(.exposure, default: 0)
        contrast = c.decode(.contrast, default: 0)
        highlights = c.decode(.highlights, default: 0)
        shadows = c.decode(.shadows, default: 0)
        whites = c.decode(.whites, default: 0)
        blacks = c.decode(.blacks, default: 0)
        texture = c.decode(.texture, default: 0)
        clarity = c.decode(.clarity, default: 0)
        dehaze = c.decode(.dehaze, default: 0)
        saturation = c.decode(.saturation, default: 0)
    }
    var isDefault: Bool { self == LocalAdjustments() }
}

// MARK: - Decoding helper

nonisolated extension KeyedDecodingContainer {
    /// Decodes `key` if present and valid, otherwise returns `value`. Never throws.
    func decode<T: Decodable>(_ key: Key, default value: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? value
    }
}
