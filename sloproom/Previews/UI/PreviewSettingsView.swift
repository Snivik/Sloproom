//
//  PreviewSettingsView.swift
//  sloproom
//
//  Preview settings (Settings window, and `SheetKind.previewSettings` sheet).
//  Values live in UserDefaults (`PreviewSettings.Keys`); every change is pushed to
//  `PreviewService.reloadSettings()` (size/quality changes regenerate previews lazily).
//  "Develop" section: how many recent Develop renders are kept (`RecentRenders`, 0 = off) and
//  their size on disk; "Clean Cache" deletes them too.
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
    @AppStorage(PreviewSettings.Keys.recentRenderCount) private var recentRenderCount = PreviewSettings().recentRenderCount

    @State private var usage: Int64?
    @State private var recentUsage: (count: Int, bytes: Int64)?
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
                    .help("Long side of the previews shown in Develop and full screen before the photo is rendered")
                    .accessibilityLabel("Standard preview size")
                    Picker("Thumbnail size", selection: $thumbnailSize) {
                        ForEach(PreviewSettings.thumbnailSizes, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .help("Long side of the grid and filmstrip thumbnails")
                    .accessibilityLabel("Thumbnail size")
                    Picker("Quality", selection: $quality) {
                        ForEach(PreviewSettings.qualities, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .help("JPEG quality of cached previews (higher = sharper, larger cache)")
                    .accessibilityLabel("Quality")
                    Toggle("Use embedded camera previews for unedited photos", isOn: $useEmbedded)
                        .help("Much faster: the camera's own JPEG inside the RAW is used until a photo is edited")
                        .accessibilityLabel("Use embedded camera previews for unedited photos")
                }
                Section {
                    LabeledContent("Keep last rendered photos") {
                        HStack(spacing: 6) {
                            TextField("", value: recentCountBinding, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 60)
                            Stepper("", value: recentCountBinding, in: 0...RecentRenders.maxLimit, step: 10)
                                .labelsHidden()
                                .help("Number of recent Develop renders kept (steps of 10; 0 = off)")
                                .accessibilityLabel("Keep last rendered photos")
                        }
                    }
                    LabeledContent("Size on disk") {
                        Text(recentUsageText).monospacedDigit()
                    }
                } header: {
                    Text("Develop")
                } footer: {
                    Text(recentRenderCount == 0
                         ? "Off: photos are rendered from the original every time they are opened in Develop."
                         : "The last \(recentRenderCount) photos rendered in Develop are kept ready, so going back to them shows a sharp image instantly instead of re-reading the original. 0 turns this off.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Size on disk") {
                        Text(usage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                            .monospacedDigit()
                    }
                    Picker("Maximum cache size", selection: $maxCacheGB) {
                        ForEach(PreviewSettings.maxCacheOptions, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) GB").tag($0) }
                    }
                    .help("The oldest previews are deleted beyond this size")
                    .accessibilityLabel("Maximum cache size")
                    HStack {
                        if jobs.isBusy {
                            PreviewActivityView()
                        }
                        Spacer()
                        Button("Clean Cache…") { confirmClean = true }
                            .help("Delete every cached preview (they are rebuilt when shown)")
                        Button("Regenerate All…") { confirmRegenerate = true }
                            .help("Rebuild the previews of every photo with the current settings")
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
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).help("Close (Return)")
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
        .onChange(of: recentRenderCount) { settingsChanged(); refreshUsage(after: 0.5) }
        // Refresh the size while jobs run / after cleaning.
        .task(id: "\(jobs.done / 50)-\(jobs.isBusy)-\(jobs.epoch)") { await measure() }
        .confirmationDialog("Delete all cached previews?", isPresented: $confirmClean) {
            Button("Clean Cache", role: .destructive) {
                jobs.discardAll()
                refreshUsage(after: 0.2)
            }
        } message: {
            Text("Previews and recent Develop renders are regenerated when photos are shown again.")
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
        recentUsage = await PreviewService.shared.recentRendersUsage()
    }

    /// Clamped 0…max (the text field accepts any number).
    private var recentCountBinding: Binding<Int> {
        Binding(get: { recentRenderCount },
                set: { recentRenderCount = min(max($0, 0), RecentRenders.maxLimit) })
    }

    private var recentUsageText: String {
        guard let recentUsage else { return "Calculating…" }
        let bytes = ByteCountFormatter.string(fromByteCount: recentUsage.bytes, countStyle: .file)
        return "\(bytes) (\(recentUsage.count) \(recentUsage.count == 1 ? "photo" : "photos"))"
    }

    private func refreshUsage(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await measure()
        }
    }
}
