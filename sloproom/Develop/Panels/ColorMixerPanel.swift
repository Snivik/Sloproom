//
//  ColorMixerPanel.swift
//  sloproom
//
//  Lightroom-style HSL mixer: tabs Hue / Saturation / Luminance / All, eight bands with colored
//  tracks (ColorMixerStage).
//

import SwiftUI

struct ColorMixerPanel: View {
    @Bindable var session: DevelopSession
    @AppStorage("develop.colorMixer.tab") private var tab: Tab = .hue

    enum Tab: String, CaseIterable, Identifiable {
        case hue = "Hue", saturation = "Saturation", luminance = "Luminance", all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        InspectorSection("Color Mixer", onReset: { session.settings.colorMixer = ColorMixer() }) {
            Picker("Mixer", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch tab {
            case .hue: group(\.hue, .hue)
            case .saturation: group(\.saturation, .saturation)
            case .luminance: group(\.luminance, .luminance)
            case .all:
                ForEach([Tab.hue, .saturation, .luminance]) { t in
                    Text(t.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    group(t == .hue ? \.hue : t == .saturation ? \.saturation : \.luminance, t)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ key: WritableKeyPath<HSLAdjustment, Double>, _ kind: Tab) -> some View {
        ForEach(ColorBand.allCases, id: \.self) { band in
            DevelopSlider(title: band.title, value: binding(band, key), range: HSLAdjustment.range,
                          step: 1, track: .gradient(Self.gradient(band, kind)),
                          onEditingChanged: { if !$0 { session.commitUndoGroup() } })
        }
    }

    private func binding(_ band: ColorBand, _ key: WritableKeyPath<HSLAdjustment, Double>) -> Binding<Double> {
        Binding {
            session.settings.colorMixer[band][keyPath: key]
        } set: {
            session.settings.colorMixer[band][keyPath: key] = $0
        }
    }

    /// Track colors: hue = neighbours on each side; saturation = gray → color; luminance = dark → light.
    static func gradient(_ band: ColorBand, _ kind: Tab) -> [Color] {
        let h = band.hsvHue
        let c = Color(hue: h / 360, saturation: 0.85, brightness: 0.9)
        switch kind {
        case .hue:
            let span = band == .red || band == .orange || band == .yellow ? 30.0 : 45.0
            let lo = (h - span + 360).truncatingRemainder(dividingBy: 360), hi = (h + span).truncatingRemainder(dividingBy: 360)
            return [Color(hue: lo / 360, saturation: 0.85, brightness: 0.9), c, Color(hue: hi / 360, saturation: 0.85, brightness: 0.9)]
        case .saturation:
            return [Color(white: 0.55), c]
        case .luminance, .all:
            return [Color(hue: h / 360, saturation: 0.9, brightness: 0.25), c, Color(hue: h / 360, saturation: 0.25, brightness: 1)]
        }
    }
}

extension ColorBand {
    var title: String { rawValue.capitalized }
    /// HSV hue of the band center (Lightroom's band layout), for track colors.
    var hsvHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 55
        case .green: 120
        case .aqua: 180
        case .blue: 225
        case .purple: 270
        case .magenta: 305
        }
    }
}
