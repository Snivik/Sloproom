//
//  CropPanel.swift
//  sloproom
//
//  Crop & Rotate: crop tool toggle (R), aspect picker (Original / Custom / catalog presets),
//  lock, rotate / flip / swap, straighten, reset, and the preset editor sheet.
//  Also installs the crop keyboard shortcuts (CropKeyMonitor) while Develop is showing.
//

import Combine
import SwiftUI

struct CropPanel: View {
    @Bindable var session: DevelopSession
    @State private var presets: [CropPreset] = []
    @State private var isEditingPresets = false
    private var store: ShortcutStore { .shared }

    var body: some View {
        InspectorSection("Crop & Rotate", id: "crop", onReset: { session.resetCrop() }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(session.isCropping ? "Done" : "Crop") { session.toggleCropTool() }
                        .help(session.isCropping ? store.help("Keep the crop", [.cropCommit, .toggleCropTool])
                                                 : store.help("Crop tool", .toggleCropTool))
                    if session.isCropping {
                        Button("Cancel") { session.cancelCrop() }
                            .help(store.help("Discard crop changes", .cropCancel))
                    }
                    Spacer()
                    Button("Reset") { session.resetCrop() }
                        .disabled(session.settings.geometry.crop.isFull && session.settings.geometry.straightenAngle == 0)
                        .help("Reset crop and straighten")
                }
                .controlSize(.small)

                HStack(spacing: 6) {
                    Picker("Aspect", selection: Binding(get: { session.cropAspectChoice }, set: { session.selectCropAspect($0) })) {
                        Text("Original").tag(CropAspectChoice.original)
                        Text("Custom").tag(CropAspectChoice.custom)
                        if !presets.isEmpty { Divider() }
                        ForEach(presets) { p in
                            Text(p.name).tag(CropAspectChoice.preset(p.id))
                        }
                    }
                    .labelsHidden()
                    .help("Crop aspect ratio (Original, Custom or a preset)")
                    Button {
                        session.setCropAspectLocked(!session.settings.geometry.aspectLocked)
                    } label: {
                        Image(systemName: session.settings.geometry.aspectLocked ? "lock.fill" : "lock.open")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(session.settings.geometry.aspectLocked ? "Aspect locked: click to unlock (or hold ⇧ while dragging)" : "Aspect unlocked: click to lock")
                    .accessibilityLabel(session.settings.geometry.aspectLocked ? "Unlock Aspect" : "Lock Aspect")
                    Button {
                        session.swapCropOrientation()
                    } label: {
                        Image(systemName: "rectangle.portrait.rotate")
                    }
                    .buttonStyle(.borderless)
                    .iconHelp("Swap portrait / landscape", shortcut: .cropSwapAspect)
                }

                HStack(spacing: 14) {
                    Button { session.rotateQuarter(clockwise: false) } label: { Image(systemName: "rotate.left") }
                        .iconHelp("Rotate Left", shortcut: .rotateLeft)
                    Button { session.rotateQuarter(clockwise: true) } label: { Image(systemName: "rotate.right") }
                        .iconHelp("Rotate Right", shortcut: .rotateRight)
                    Button { session.flipHorizontally() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .iconHelp("Flip Horizontal")
                    Spacer()
                    Button("Edit Presets…") { isEditingPresets = true }
                        .controlSize(.small)
                        .help("Add, rename, reorder or delete crop aspect presets")
                }
                .buttonStyle(.borderless)

                DevelopSlider(title: "Straighten", value: session.straightenBinding, range: Geometry.straightenRange,
                              format: .custom { String(format: "%.1f°", $0) }, step: 0.1) { editing in
                    if editing { session.beginStraighten() } else { session.endStraighten() }
                }

                if session.isCropping {
                    Text("Drag corners or edges to resize, inside to move, outside to rotate. \(store.display(.cropSwapAspect)) swaps orientation, \(store.display(.cropGridOverlay)) cycles the grid (\(session.cropTool.gridMode.rawValue)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cropKeyboardShortcuts(session: session)
        .onAppear { loadPresets() }
        .onChange(of: ObjectIdentifier(session)) { _, _ in session.cropTool.presets = presets }
        .onReceive(NotificationCenter.default.publisher(for: Catalog.didChange)) { note in
            if Catalog.change(from: note) == .cropPresets { loadPresets() }
        }
        .sheet(isPresented: $isEditingPresets) {
            CropPresetsEditor(catalog: session.catalog)
        }
    }

    private func loadPresets() {
        let catalog = session.catalog
        do {
            try catalog.ensureDefaultCropPresets()
            presets = try catalog.allCropPresets()
        } catch {
            presets = []
        }
        session.cropTool.presets = presets
    }
}
