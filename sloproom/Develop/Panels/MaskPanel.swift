//
//  MaskPanel.swift
//  sloproom
//
//  Masks: "Create New Mask" (Linear Gradient / Radial Gradient / Brush), the mask list
//  (select, show/hide, rename, duplicate, invert, delete) and, for the selected mask, its
//  shape options and local adjustment sliders. Drawing / editing happens in MaskOverlayView.
//

import SwiftUI

struct MaskPanel: View {
    @Bindable var session: DevelopSession
    @State private var tool = MaskToolState.shared
    @State private var renamingID: UUID?
    @State private var draftName = ""
    private var store: ShortcutStore { .shared }

    var body: some View {
        InspectorSection("Masks") {
            VStack(alignment: .leading, spacing: 8) {
                createButtons
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                if !session.settings.masks.isEmpty { maskList }
                if let mask = session.selectedMask {
                    Divider()
                    options(for: mask)
                    Divider()
                    adjustments(for: mask)
                }
                if session.activeTool == .mask {
                    HStack {
                        Toggle("Show Overlay" + (store.binding(for: .maskOverlay).map { " (\($0.display))" } ?? ""), isOn: $tool.showOverlay)
                            .toggleStyle(.checkbox)
                            .help(store.help("Show the selected mask's coverage in red", .maskOverlay))
                        Spacer()
                        Button("Done") { session.finishMasking() }
                            .help(store.help("Leave the mask tool", .maskCancel))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Create

    private var createButtons: some View {
        HStack(spacing: 6) {
            ForEach(MaskKind.allCases, id: \.self) { kind in
                let active = tool.pendingKind == kind && session.activeTool == .mask
                Button { session.beginCreatingMask(kind) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: kind.systemImage).font(.body)
                        Text(kind.title.replacingOccurrences(of: " Gradient", with: "")).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12)))
                .help("Create New Mask: \(kind.title)")
                .accessibilityLabel("New \(kind.title) Mask")
            }
        }
    }

    private var hint: String? {
        switch tool.pendingKind {
        case .linear?: return "Drag on the photo from where the effect is full to where it ends."
        case .radial?: return "Drag on the photo from the center outwards."
        case .brush?: return "Paint on the photo. ⌥ erases, \(brushKeys) change the size."
        case nil:
            if session.settings.masks.isEmpty { return "Create a mask, then adjust it with the sliders." }
            if session.activeTool == .mask, session.selectedMask?.brush != nil {
                return "Paint to add, ⌥ or Erase to remove. \(brushKeys) size."
            }
            return nil
        }
    }

    private var brushKeys: String {
        [store.display(.brushSmaller), store.display(.brushLarger)].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    // MARK: List

    private var maskList: some View {
        VStack(spacing: 2) {
            ForEach(session.settings.masks) { mask in
                row(mask)
            }
        }
    }

    private func row(_ mask: Mask) -> some View {
        let selected = mask.id == session.selectedMaskID
        return HStack(spacing: 6) {
            Button {
                session.updateMask(mask.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                    .frame(width: 16)
                    .foregroundStyle(mask.isEnabled ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .iconHelp(mask.isEnabled ? "Hide mask effect" : "Show mask effect")

            Image(systemName: mask.shape.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if renamingID == mask.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { commitRename(mask.id) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(mask.name)
                    .lineLimit(1)
                    .foregroundStyle(mask.isEnabled ? .primary : .secondary)
            }
            Spacer(minLength: 4)
            if mask.inverted {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).help("Inverted")
                    .accessibilityLabel("Inverted")
            }
            Menu {
                menuItems(mask)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .iconHelp("Mask actions: rename, duplicate, invert, hide, delete")
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectMask(mask.id) }
        .contextMenu { menuItems(mask) }
    }

    @ViewBuilder
    private func menuItems(_ mask: Mask) -> some View {
        Button("Rename…") {
            draftName = mask.name
            renamingID = mask.id
        }
        Button("Duplicate") { session.duplicateMask(mask.id) }
        Button(mask.inverted ? "Don't Invert" : "Invert") {
            session.updateMask(mask.id) { $0.inverted.toggle() }
        }
        Button(mask.isEnabled ? "Hide" : "Show") {
            session.updateMask(mask.id) { $0.isEnabled.toggle() }
        }
        Divider()
        Button("Delete", role: .destructive) { session.deleteMask(mask.id) }
    }

    private func commitRename(_ id: UUID) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.updateMask(id) { $0.name = name } }
        renamingID = nil
    }

    // MARK: Selected mask

    @ViewBuilder
    private func options(for mask: Mask) -> some View {
        Toggle("Invert", isOn: Binding(
            get: { session.mask(id: mask.id)?.inverted ?? false },
            set: { v in session.updateMask(mask.id) { $0.inverted = v } }))
            .toggleStyle(.checkbox)
            .help("Apply the adjustments outside the mask instead")
        if mask.radial != nil {
            DevelopSlider(title: "Feather", value: Binding(
                get: { session.mask(id: mask.id)?.radial?.feather ?? 50 },
                set: { v in session.updateMask(mask.id) { $0.radial?.feather = v } }),
                range: 0...100, defaultValue: 50, format: .integer, onEditingChanged: endEdit)
        }
        if mask.brush != nil {
            Toggle("Erase (⌥)", isOn: $tool.eraseMode).toggleStyle(.checkbox)
                .help("Brush strokes erase the mask (or hold ⌥ while painting)")
            DevelopSlider(title: "Size", value: $tool.brushSize, range: MaskToolState.sizeRange, defaultValue: 16,
                          scale: .logarithmic, format: .integer)
                .help(store.help("Brush size on screen: the same at every zoom, so zooming in paints finer strokes", [.brushSmaller, .brushLarger]))
            DevelopSlider(title: "Feather", value: $tool.brushFeather, range: 0...100, defaultValue: 50, format: .integer)
            DevelopSlider(title: "Flow", value: $tool.brushFlow, range: 0...100, defaultValue: 100, format: .integer)
            Button("Clear Strokes") {
                session.commitUndoGroup()
                session.updateMask(mask.id) { $0.brush?.strokes = [] }
                session.commitUndoGroup()
            }
            .controlSize(.small)
            .disabled(mask.brush?.strokes.isEmpty ?? true)
            .help("Remove every brush stroke of this mask")
        }
    }

    private static let sliders: [(String, WritableKeyPath<LocalAdjustments, Double>)] = [
        ("Temp", \.temperature), ("Tint", \.tint), ("Exposure", \.exposure), ("Contrast", \.contrast),
        ("Highlights", \.highlights), ("Shadows", \.shadows), ("Whites", \.whites), ("Blacks", \.blacks),
        ("Texture", \.texture), ("Clarity", \.clarity), ("Dehaze", \.dehaze), ("Saturation", \.saturation),
    ]

    @ViewBuilder
    private func adjustments(for mask: Mask) -> some View {
        HStack {
            Text("Adjustments").font(.subheadline.weight(.semibold))
            Spacer()
            Button("Reset") {
                session.commitUndoGroup()
                session.updateMask(mask.id) { $0.adjustments = LocalAdjustments() }
                session.commitUndoGroup()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(mask.adjustments.isDefault)
            .help("Reset this mask's adjustments")
        }
        ForEach(Self.sliders, id: \.0) { title, keyPath in
            let isExposure = keyPath == \LocalAdjustments.exposure
            DevelopSlider(title: title, value: Binding(
                get: { session.mask(id: mask.id)?.adjustments[keyPath: keyPath] ?? 0 },
                set: { v in session.updateMask(mask.id) { $0.adjustments[keyPath: keyPath] = v } }),
                range: isExposure ? LocalAdjustments.exposureRange : LocalAdjustments.range,
                format: isExposure ? .signedDecimal(2) : .signedInteger,
                step: isExposure ? 0.01 : 1,
                onEditingChanged: endEdit)
        }
    }

    private func endEdit(_ editing: Bool) {
        if !editing { session.commitUndoGroup() }
    }
}
