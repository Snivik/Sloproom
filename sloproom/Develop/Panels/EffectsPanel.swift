//
//  EffectsPanel.swift
//  sloproom
//
//  Post-crop vignetting and grain (EffectsStage).
//

import SwiftUI

struct EffectsPanel: View {
    @Bindable var session: DevelopSession

    var body: some View {
        InspectorSection("Effects", onReset: { session.settings.effects = Effects() }) {
            Text("Post-Crop Vignetting").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            slider("Amount", \.vignetteAmount, -100...100,
                   track: .gradient([Color(white: 0.1), Color(white: 0.55), Color(white: 0.95)]))
            Group {
                slider("Midpoint", \.vignetteMidpoint, 0...100, defaultValue: 50, format: .integer)
                slider("Roundness", \.vignetteRoundness, -100...100)
                slider("Feather", \.vignetteFeather, 0...100, defaultValue: 50, format: .integer)
            }
            .disabled(session.settings.effects.vignetteAmount == 0)

            Text("Grain").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            slider("Amount", \.grainAmount, 0...100, format: .integer)
            Group {
                slider("Size", \.grainSize, 0...100, defaultValue: 25, format: .integer)
                slider("Roughness", \.grainRoughness, 0...100, defaultValue: 50, format: .integer)
            }
            .disabled(session.settings.effects.grainAmount == 0)
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<Effects, Double>, _ range: ClosedRange<Double>,
                        defaultValue: Double = 0, format: DevelopSlider.Format = .signedInteger,
                        track: DevelopSlider.Track = .plain) -> some View {
        DevelopSlider(title: title, value: $session.settings.effects[dynamicMember: key], range: range,
                      defaultValue: defaultValue, format: format, step: 1, track: track,
                      onEditingChanged: { if !$0 { session.commitUndoGroup() } })
    }
}
