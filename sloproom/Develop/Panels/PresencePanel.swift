//
//  PresencePanel.swift
//  sloproom
//
//  Texture, clarity, dehaze, vibrance, saturation (PresenceStage).
//

import SwiftUI

struct PresencePanel: View {
    @Bindable var session: DevelopSession

    var body: some View {
        InspectorSection("Presence", onReset: { session.settings.presence = Presence() }) {
            slider("Texture", \.texture)
            slider("Clarity", \.clarity)
            slider("Dehaze", \.dehaze)
            Divider().padding(.vertical, 2)
            slider("Vibrance", \.vibrance, track: .gradient([Color(white: 0.55), Color(red: 0.2, green: 0.55, blue: 0.95)]))
            slider("Saturation", \.saturation, track: .gradient([Color(white: 0.55), Color(red: 0.95, green: 0.25, blue: 0.3)]))
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<Presence, Double>,
                        track: DevelopSlider.Track = .plain) -> some View {
        DevelopSlider(title: title, value: $session.settings.presence[dynamicMember: key], range: Presence.range,
                      step: 1, track: track, onEditingChanged: commit)
    }

    private func commit(_ editing: Bool) { if !editing { session.commitUndoGroup() } }
}
