//
//  ExportSheet.swift
//  sloproom
//
//  The small Export sheet: destination folder, JPEG quality, Export / Cancel; then progress and
//  a summary with "Show in Finder". Fixed choices: full resolution, sRGB, metadata kept.
//

import SwiftUI

struct ExportSheet: View {
    @Bindable var controller: ExportController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(controller.title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("Destination:").gridColumnAlignment(.trailing)
                    destinationRow
                }
                GridRow {
                    Text("JPEG Quality:")
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(controller.quality) },
                                              set: { controller.quality = Int($0.rounded()) }),
                               in: 0...100)
                        .help("JPEG quality: higher = better image, larger files")
                        .accessibilityLabel("JPEG Quality")
                        Text("\(controller.quality)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
            .disabled(controller.phase == .exporting)
            Text("Full resolution · sRGB · metadata kept")
                .font(.caption)
                .foregroundStyle(.secondary)
            statusSection
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(controller.phase == .exporting)
    }

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                if let d = controller.destination {
                    Text(d.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(d.path)
                } else {
                    Text("No folder chosen").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if controller.isCheckingDestination { ProgressView().controlSize(.small) }
                Button("Choose…") { controller.chooseDestination() }
                    .help("Choose the folder the JPEGs are written to")
            }
            if let problem = controller.destinationProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .exporting:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(controller.progress.done), total: Double(max(controller.progress.total, 1)))
                Text(controller.progressText).font(.callout).foregroundStyle(.secondary)
            }
        case .finished:
            if let result = controller.result {
                VStack(alignment: .leading, spacing: 4) {
                    Label(result.summary, systemImage: result.skipped.isEmpty && result.stopError == nil && !result.wasCancelled
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.skipped.isEmpty && result.stopError == nil ? Color.primary : Color.orange)
                    ForEach(result.skipped.prefix(5), id: \.photoID) { s in
                        Text("\(s.fileName): \(s.reason.description)").font(.caption).foregroundStyle(.secondary)
                    }
                    if result.skipped.count > 5 {
                        Text("and \(result.skipped.count - 5) more").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = result.stopError {
                        Text(error.description).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if controller.phase == .finished, controller.result?.exported.isEmpty == false {
                Button("Show in Finder") { controller.showInFinder() }
                    .help("Reveal the exported files in Finder")
            }
            Spacer()
            switch controller.phase {
            case .idle:
                Button("Cancel") { controller.close() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without exporting (Esc)")
                Button("Export") { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .help("Export full-resolution sRGB JPEGs (Return)")
                    .disabled(!controller.canExport)
            case .exporting:
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop exporting (Esc); finished files are kept")
            case .finished:
                Button("Done") { controller.close() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close (Return)")
            }
        }
    }
}
