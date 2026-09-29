//
//  DevelopInspectorView.swift
//  sloproom
//
//  Right-hand panel: history buttons, tool picker, and one collapsible section per panel file.
//

import SwiftUI

struct DevelopInspectorView: View {
    @Bindable var session: DevelopSession

    var body: some View {
        VStack(spacing: 0) {
            HistogramView(session: session)
                .padding([.horizontal, .top], 10)
            HStack {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!session.canUndo).help("Undo (⌘Z)")
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!session.canRedo).help("Redo (⇧⌘Z)")
                Spacer()
                Button("Reset All") { session.resetAll() }
                    .disabled(session.settings.isDefault)
            }
            .buttonStyle(.borderless)
            .padding(10)

            Picker("Tool", selection: $session.activeTool) {
                Text("Adjust").tag(DevelopTool.none)
                Text("Crop").tag(DevelopTool.crop)
                Text("Mask").tag(DevelopTool.mask)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.activeTool == .mask { MaskPanel(session: session) } // on top while masking
                    WhiteBalancePanel(session: session)
                    TonePanel(session: session)
                    PresencePanel(session: session)
                    ColorMixerPanel(session: session)
                    EffectsPanel(session: session)
                    CropPanel(session: session)
                    if session.activeTool != .mask { MaskPanel(session: session) }
                }
            }
        }
        .background(.background)
    }
}
