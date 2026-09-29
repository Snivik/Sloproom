//
//  WhiteBalancePanel.swift
//  sloproom
//
//  As Shot / Custom white balance, Auto, and an eyedropper (click a neutral point on the
//  canvas). Moving a slider while "As Shot" switches to Custom, starting from the camera's values.
//

import SwiftUI

struct WhiteBalancePanel: View {
    @Bindable var session: DevelopSession

    var body: some View {
        InspectorSection("White Balance", onReset: { session.settings.whiteBalance = WhiteBalance() }) {
            HStack(spacing: 6) {
                Button {
                    session.isPickingWhiteBalance.toggle()
                } label: {
                    Image(systemName: "eyedropper")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(session.isPickingWhiteBalance ? Color.accentColor : .primary)
                .help("White balance selector: click a neutral area of the photo")
                .disabled(!isRAW)

                Picker("WB", selection: modeBinding) {
                    Text("As Shot").tag(WhiteBalance.Mode.asShot)
                    Text("Custom").tag(WhiteBalance.Mode.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button("Auto") { session.setWhiteBalance(from: .auto) }
                    .controlSize(.small)
                    .disabled(!isRAW)
                    .help("Estimate white balance from the photo")
            }

            DevelopSlider(title: "Temp", value: customBinding(\.temperature), range: WhiteBalance.temperatureRange,
                          defaultValue: session.asShotTemperature ?? 5500, scale: .logarithmic, format: .kelvin, step: 10,
                          track: .gradient([Color(red: 0.25, green: 0.45, blue: 0.95), Color(white: 0.85),
                                            Color(red: 0.95, green: 0.8, blue: 0.2)]),
                          onEditingChanged: commit)
            DevelopSlider(title: "Tint", value: customBinding(\.tint), range: WhiteBalance.tintRange,
                          defaultValue: session.asShotTint ?? 0, format: .signedInteger, step: 1,
                          track: .gradient([Color(red: 0.2, green: 0.75, blue: 0.3), Color(white: 0.85),
                                            Color(red: 0.85, green: 0.3, blue: 0.8)]),
                          onEditingChanged: commit)
        }
    }

    private var isRAW: Bool { session.source?.isRAW ?? true }

    private func commit(_ editing: Bool) { if !editing { session.commitUndoGroup() } }

    private var modeBinding: Binding<WhiteBalance.Mode> {
        Binding {
            session.settings.whiteBalance.mode
        } set: { mode in
            var wb = session.settings.whiteBalance
            if mode == .custom && wb.mode == .asShot { seedFromAsShot(&wb) }
            wb.mode = mode
            session.settings.whiteBalance = wb
        }
    }

    /// Shows as-shot values while in As Shot mode; writing switches to Custom.
    private func customBinding(_ key: WritableKeyPath<WhiteBalance, Double>) -> Binding<Double> {
        Binding {
            let wb = session.settings.whiteBalance
            if wb.mode == .asShot {
                var seeded = wb
                seedFromAsShot(&seeded)
                return seeded[keyPath: key]
            }
            return wb[keyPath: key]
        } set: { value in
            var wb = session.settings.whiteBalance
            if wb.mode == .asShot { seedFromAsShot(&wb); wb.mode = .custom }
            wb[keyPath: key] = value
            session.settings.whiteBalance = wb
        }
    }

    private func seedFromAsShot(_ wb: inout WhiteBalance) {
        wb.temperature = session.asShotTemperature ?? 5500
        wb.tint = session.asShotTint ?? 0
    }
}
