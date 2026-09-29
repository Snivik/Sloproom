//
//  PreviewSettingsView.swift
//  sloproom
//
//  Preview settings (Settings window, and `SheetKind.previewSettings` sheet).
//  Values live in UserDefaults (`PreviewSettings.Keys`); every change is pushed to
//  `PreviewService.reloadSettings()` (size/quality changes regenerate previews lazily).
//

import SwiftUI

struct PreviewSettingsView: View {
    /// The Settings window has no Done button (only the sheet does).
    var showsDoneButton = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    @AppStorage(PreviewSettings.Keys.standardSize) private var standardSize = PreviewSettings().standardSize
    @AppStorage(PreviewSettings.Keys.thumbnailSize) private var thumbnailSize = PreviewSettings().thumbnailSize
    @AppStorage(PreviewSettings.Keys.quality) private var quality = PreviewSettings().quality
    @AppStorage(PreviewSettings.Keys.useEmbeddedPreviews) private var useEmbedded = PreviewSettings().useEmbeddedPreviews
    @AppStorage(PreviewSettings.Keys.maxCacheGB) private var maxCacheGB = PreviewSettings().maxCacheGB

    @State private var usage: Int64?
    @State private var confirmClean = false
    @State private var confirmRegenerate = false
    private var jobs: PreviewJobs { PreviewJobs.shared }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Previews") {
                    Picker("Standard preview size", selection: $standardSize) {
                        ForEach(PreviewSettings.standardSizes, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Thumbnail size", selection: $thumbnailSize) {
                        ForEach(PreviewSettings.thumbnailSizes, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Quality", selection: $quality) {
                        ForEach(PreviewSettings.qualities, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    Toggle("Use embedded camera previews for unedited photos", isOn: $useEmbedded)
                }
                Section {
                    LabeledContent("Size on disk") {
                        Text(usage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                            .monospacedDigit()
                    }
                    Picker("Maximum cache size", selection: $maxCacheGB) {
                        ForEach(PreviewSettings.maxCacheOptions, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) GB").tag($0) }
                    }
                    HStack {
                        if jobs.isBusy {
                            PreviewActivityView()
                        }
                        Spacer()
                        Button("Clean Cache…") { confirmClean = true }
                        Button("Regenerate All…") { confirmRegenerate = true }
                    }
                } header: {
                    Text("Cache")
                } footer: {
                    Text("Least recently used previews are removed when the cache grows beyond its maximum size.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if isPresented && showsDoneButton {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: standardSize) { settingsChanged() }
        .onChange(of: thumbnailSize) { settingsChanged() }
        .onChange(of: quality) { settingsChanged() }
        .onChange(of: useEmbedded) { settingsChanged() }
        .onChange(of: maxCacheGB) { settingsChanged(); refreshUsage(after: 0.5) }
        // Refresh the size while jobs run / after cleaning.
        .task(id: "\(jobs.done / 50)-\(jobs.isBusy)-\(jobs.epoch)") { await measure() }
        .confirmationDialog("Delete all cached previews?", isPresented: $confirmClean) {
            Button("Clean Cache", role: .destructive) {
                jobs.discardAll()
                refreshUsage(after: 0.2)
            }
        } message: {
            Text("Previews are regenerated when photos are shown again.")
        }
        .confirmationDialog("Regenerate all previews?", isPresented: $confirmRegenerate) {
            Button("Regenerate All") { jobs.regenerateAll() }
        } message: {
            Text("Deletes the cache and builds thumbnails and standard previews for every photo in the background.")
        }
    }

    private func settingsChanged() {
        PreviewService.shared.reloadSettings()
    }

    private func measure() async {
        usage = await PreviewService.shared.diskUsage()
    }

    private func refreshUsage(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await measure()
        }
    }
}
