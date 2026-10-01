//
//  EditSections.swift
//  sloproom
//
//  The sections of `EditSettings` as the Develop panels show them, for Paste Settings and Sync
//  Settings checklists (UI-free; Tools/actions_check.swift). Copying a section copies the whole
//  section struct, never single fields.
//

import Foundation

nonisolated enum EditSection: String, CaseIterable, Sendable, Hashable, Identifiable {
    case whiteBalance, tone, presence, colorMixer, effects, masks, cropRotate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .tone: "Tone"
        case .presence: "Presence"
        case .colorMixer: "Color Mixer"
        case .effects: "Effects"
        case .masks: "Masks"
        case .cropRotate: "Crop & Rotate"
        }
    }

    var help: String {
        switch self {
        case .whiteBalance: "Temperature, tint (As Shot / Custom)"
        case .tone: "Exposure, contrast, highlights, shadows, whites, blacks"
        case .presence: "Texture, clarity, dehaze, vibrance, saturation"
        case .colorMixer: "Hue / saturation / luminance per color band"
        case .effects: "Vignette and grain"
        case .masks: "Every mask with its local adjustments (replaces the target's masks)"
        case .cropRotate: "Crop rectangle, aspect, straighten, rotation and flip (replaces the target's)"
        }
    }

    /// Paste Settings until the user chooses otherwise: the global adjustments (what Copy / Paste
    /// Settings always copied; the target keeps its own crop and masks).
    static let pasteDefault: Set<EditSection> = [.whiteBalance, .tone, .presence, .colorMixer, .effects]
    /// Sync Settings: everything but the crop.
    static let syncDefault: Set<EditSection> = [.whiteBalance, .tone, .presence, .colorMixer, .effects, .masks]

    /// Persisted as a comma-separated list of raw values.
    static func decode(_ string: String?) -> Set<EditSection>? {
        guard let string else { return nil }
        return Set(string.split(separator: ",").compactMap { EditSection(rawValue: String($0)) })
    }

    static func encode(_ sections: Set<EditSection>) -> String {
        allCases.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }
}

nonisolated extension EditSettings {
    /// `self` with the chosen sections taken from `source` (the rest unchanged).
    func replacing(_ sections: Set<EditSection>, from source: EditSettings) -> EditSettings {
        var out = self
        for section in sections {
            switch section {
            case .whiteBalance: out.whiteBalance = source.whiteBalance
            case .tone: out.tone = source.tone
            case .presence: out.presence = source.presence
            case .colorMixer: out.colorMixer = source.colorMixer
            case .effects: out.effects = source.effects
            case .masks: out.masks = source.masks
            case .cropRotate: out.geometry = source.geometry
            }
        }
        return out
    }

    /// Sections in which `self` differs from `other`.
    func differingSections(from other: EditSettings) -> Set<EditSection> {
        Set(EditSection.allCases.filter { replacing([$0], from: other) != self })
    }
}
