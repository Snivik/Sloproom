//
//  TonePanel.swift
//  sloproom
//
//  Exposure (RawDecodeStage) and contrast / highlights / shadows / whites / blacks (ToneStage).
//

import SwiftUI

struct TonePanel: View {
    @Bindable var session: DevelopSession

    var body: some View {
        InspectorSection("Tone", onReset: { session.settings.tone = Tone() }) {
            DevelopSlider(title: "Exposure", value: $session.settings.tone.exposure, range: Tone.exposureRange,
                          format: .signedDecimal(2), step: 0.01,
                          track: .gradient([Color(white: 0.1), Color(white: 0.9)]), onEditingChanged: commit)
            slider("Contrast", \.contrast)
            Divider().padding(.vertical, 2)
            slider("Highlights", \.highlights)
            slider("Shadows", \.shadows)
            slider("Whites", \.whites)
            slider("Blacks", \.blacks)
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<Tone, Double>) -> some View {
        DevelopSlider(title: title, value: $session.settings.tone[dynamicMember: key], range: Tone.range,
                      step: 1, onEditingChanged: commit)
    }

    private func commit(_ editing: Bool) { if !editing { session.commitUndoGroup() } }
}
