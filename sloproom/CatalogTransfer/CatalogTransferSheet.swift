//
//  CatalogTransferSheet.swift
//  sloproom
//
//  File > Export Catalog… / Import Catalog… menu items and the sheet showing each step
//  (`CatalogTransferController.step`). Attached to the main window with `.catalogTransferSheet(model:)`.
//

import AppKit
import SwiftUI

struct CatalogTransferCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {   // after Import… / Export… (SloproomCommands, ExportCommands)
            Divider()
            Button("Export Catalog…") { CatalogTransferController.shared.chooseExportDestination(model: model) }
            Button("Import Catalog…") { CatalogTransferController.shared.chooseImportFile(model: model) }
        }
    }
}

extension View {
    func catalogTransferSheet(model: AppModel) -> some View {
        modifier(CatalogTransferSheetModifier(model: model))
    }
}

private struct CatalogTransferSheetModifier: ViewModifier {
    let model: AppModel
    private var controller: CatalogTransferController { .shared }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { controller.step != nil }, set: { if !$0 { controller.dismiss() } })) {
            CatalogTransferSheet(model: model)
        }
    }
}

struct CatalogTransferSheet: View {
    let model: AppModel
    private var controller: CatalogTransferController { .shared }

    var body: some View {
        Group {
            switch controller.step {
            case .working(let text)?: working(text)
            case .exported(let result)?: exported(result)
            case .summary(let summary)?: ImportSummaryView(summary: summary, model: model)
            case .imported(let outcome)?: imported(outcome)
            case .failed(let title, let message)?: failed(title, message)
            case nil: EmptyView()
            }
        }
        .frame(width: 540)
        .interactiveDismissDisabled(controller.isWorking)
    }

    // MARK: Steps

    private func working(_ text: String) -> some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text(text).font(.headline)
            Spacer()
        }
        .padding(24)
    }

    private func exported(_ r: CatalogExportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("checkmark.circle.fill", .green, "Catalog Exported", r.url.lastPathComponent)
            Text("\(counts(r.info)) · \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))")
            Text("Previews are not included; the Mac that imports this catalog rebuilds them. Import it there with File > Import Catalog…")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                Spacer()
                Button("Done") { controller.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func imported(_ o: CatalogTransferController.ImportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("checkmark.circle.fill", .green, "Catalog Imported", o.sourceName)
            Text(counts(o.info))
            Text("Your previous catalog was backed up to “\(o.backup.path)”.")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if o.needsAttention > 0 {
                Divider()
                Label(o.needsAttention == 1 ? "1 drive needs attention" : "\(o.needsAttention) drives need attention",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                Text("Photos on these drives stay offline until Sloproom can read them. Connect the drive and click Grant Access…. If the photos are now somewhere else (the drive was renamed, or it is mounted at a different path on this Mac), click Relink… and choose the folder that contains them. You can do this later in Settings > Drives.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    RootsAccessView().padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([o.backup]) }
                Spacer()
                Button("Done") { controller.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func failed(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("exclamationmark.triangle.fill", .orange, title, nil)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { controller.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func counts(_ i: CatalogInfo) -> String {
        "\(i.photoCount.formatted()) photos · \(i.editedPhotoCount.formatted()) edited · \(i.folderCount.formatted()) folders"
    }
}

/// Before replacing: what the file contains, its drives, and what happens to the current catalog.
private struct ImportSummaryView: View {
    let summary: CatalogTransferController.ImportSummary
    let model: AppModel
    private var info: CatalogInfo { summary.candidate.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("square.and.arrow.down.on.square", .accentColor, "Import Catalog", summary.candidate.sourceURL.lastPathComponent)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                row("Photos", info.photoCount.formatted())
                row("Edited photos", info.editedPhotoCount.formatted())
                row("Flags", "\(info.pickedCount.formatted()) picked · \(info.rejectedCount.formatted()) rejected")
                row("Folders", info.folderCount.formatted())
                row("Exported", exportedText)
                if let v = info.appVersion { row("Created with", "Sloproom \(v)" + (info.appBuild.map { " (\($0))" } ?? "")) }
                row("Catalog format", schemaText)
            }
            if !summary.roots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drives").font(.headline)
                    ForEach(summary.roots) { r in
                        HStack(spacing: 8) {
                            Image(systemName: RootAccess.volumeName(for: r.root.path) == nil ? "folder" : "externaldrive")
                                .foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.root.displayName ?? r.root.url.lastPathComponent).lineLimit(1)
                                Text(r.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Label(r.status.title, systemImage: RootsAccessView.symbol(r.status))
                                .font(.callout).foregroundStyle(RootsAccessView.color(r.status))
                        }
                    }
                    if summary.roots.contains(where: { $0.status != .granted }) {
                        Text("After importing you can grant access to these drives, or relink them if they are at a different location on this Mac.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let warning = summary.candidate.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                Text(replaceText).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { CatalogTransferController.shared.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace Current Catalog") { Task { await CatalogTransferController.shared.replace(model: model) } }
            }
        }
        .padding(20)
    }

    private var exportedText: String {
        guard info.isExport, let date = info.exportedAt else {
            let modified = summary.candidate.fileDate.map { ", modified \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "Not an export (catalog file\(modified))"
        }
        return date.formatted(date: .abbreviated, time: .shortened) + (info.sourceMac.map { " on “\($0)”" } ?? "")
    }

    private var schemaText: String {
        let v = "Version \(info.schemaVersion)"
        return summary.candidate.needsMigration ? v + " — upgraded to \(Catalog.schemaVersion) after importing" : v
    }

    private var replaceText: String {
        let current = summary.current.map { "(\($0.photoCount.formatted()) photos, \($0.folderCount.formatted()) folders) " } ?? ""
        return "Replacing discards the catalog you are using now \(current)after backing it up to the Backups folder next to it. Photo files are never touched. Previews are rebuilt for the imported catalog."
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private func header(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String?) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.bold())
            if let subtitle { Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        }
    }
}
