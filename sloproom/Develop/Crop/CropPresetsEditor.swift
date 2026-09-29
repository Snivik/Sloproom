//
//  CropPresetsEditor.swift
//  sloproom
//
//  "Edit Presets…" sheet: add, rename, change ratio, delete and reorder (drag) the catalog's
//  crop presets. Presets are global (same for all photos). Edits are saved as you type.
//

import SwiftUI

struct CropPresetsEditor: View {
    let catalog: Catalog
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [CropPreset] = []
    /// Last saved state per id (to only write rows that changed).
    @State private var saved: [Int64: CropPreset] = [:]
    @State private var newName = ""
    @State private var newW: Double = 4
    @State private var newH: Double = 5
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop Presets").font(.headline)
            Text("Shown in every photo's aspect menu. Drag to reorder.")
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach($presets) { $preset in
                    row($preset)
                }
                .onMove(perform: move)
            }
            .frame(minHeight: 220)

            HStack(spacing: 6) {
                TextField("New preset name", text: $newName)
                ratioField("W", $newW)
                Text(":")
                ratioField("H", $newH)
                Button("Add", action: add)
                    .disabled(!isValid(name: newName, w: newW, h: newH))
            }

            HStack {
                if let errorText { Text(errorText).font(.callout).foregroundStyle(.red) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear(perform: load)
        .onChange(of: presets) { _, new in saveChanged(new) }
    }

    private func row(_ preset: Binding<CropPreset>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            TextField("Name", text: preset.name)
            ratioField("W", preset.ratioW)
            Text(":")
            ratioField("H", preset.ratioH)
            Button {
                delete(preset.wrappedValue)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete preset")
        }
    }

    private func ratioField(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
    }

    private func isValid(name: String, w: Double, h: Double) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && w > 0 && h > 0 && w.isFinite && h.isFinite
    }

    // MARK: Catalog

    private func load() {
        attempt {
            presets = try catalog.allCropPresets()
            saved = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        }
    }

    private func saveChanged(_ list: [CropPreset]) {
        for p in list where saved[p.id] != p {
            guard isValid(name: p.name, w: p.ratioW, h: p.ratioH) else { continue }
            attempt {
                try catalog.updateCropPreset(p)
                saved[p.id] = p
            }
        }
    }

    private func add() {
        attempt {
            try catalog.createCropPreset(name: newName.trimmingCharacters(in: .whitespaces), ratioW: newW, ratioH: newH)
            newName = ""
            load()
        }
    }

    private func delete(_ preset: CropPreset) {
        attempt {
            try catalog.deleteCropPreset(id: preset.id)
            load()
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = presets
        list.move(fromOffsets: source, toOffset: destination)
        attempt {
            try catalog.reorderCropPresets(ids: list.map(\.id))
            for i in list.indices { list[i].sortOrder = i; saved[list[i].id]?.sortOrder = i }
            presets = list
        }
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
