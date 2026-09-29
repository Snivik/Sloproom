//
//  CatalogTransferController.swift
//  sloproom
//
//  File > Export Catalog… / Import Catalog… flows (MainActor). Engine: `CatalogTransfer`.
//  One sheet (`CatalogTransferSheet`) shows the current step: working / exported / import summary /
//  imported (+ drives that need attention) / failed.
//
//  Replace (in-process, no relaunch): leave Develop and flush its saves, empty the grid and
//  cancel preview builds, wait briefly for in-flight preview loads, then off-main: back up →
//  close → swap files → reopen. Back on main: reset security scopes (cached per root id, ids
//  differ between catalogs), discard the Previews directory + memory cache (keyed by photo id),
//  and hand the new catalog to `AppModel.replaceCatalog(with:)`.
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class CatalogTransferController {
    static let shared = CatalogTransferController()

    enum Step {
        case working(String)
        case exported(CatalogExportResult)
        case summary(ImportSummary)
        case imported(ImportOutcome)
        case failed(title: String, message: String)
    }

    nonisolated struct RootRow: Identifiable, Sendable {
        var root: Root
        var status: RootAccessStatus
        var id: Int64 { root.id }
    }

    nonisolated struct ImportSummary: Sendable {
        var candidate: CatalogImportCandidate
        var roots: [RootRow]
        /// The catalog that would be replaced.
        var current: CatalogInfo?
    }

    nonisolated struct ImportOutcome: Sendable {
        var info: CatalogInfo
        var sourceName: String
        var backup: URL
        var needsAttention: Int
        var seconds: Double
    }

    /// nil = no sheet.
    var step: Step?
    var isWorking: Bool { if case .working = step { true } else { false } }

    static var catalogType: UTType {
        UTType(filenameExtension: CatalogTransfer.fileExtension, conformingTo: .data) ?? .data
    }

    // MARK: - Export

    /// File > Export Catalog…: save panel, then export.
    func chooseExportDestination(model: AppModel) {
        guard canStart(model: model) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Catalog"
        panel.prompt = "Export"
        panel.message = "Exports photos, folders, flags, ratings and edits as one file. Previews are not included (they are rebuilt)."
        panel.nameFieldStringValue = CatalogTransfer.defaultExportName()
        panel.allowedContentTypes = [Self.catalogType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export(to: url, model: model) }
    }

    func export(to url: URL, model: AppModel) async {
        guard canStart(model: model) else { return }
        model.developSession?.saveNow()
        DevelopSession.flushPendingSaves()
        step = .working("Exporting catalog…")
        let catalog = model.catalog
        let (version, build) = Self.appVersion
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try CatalogTransfer.exportCatalog(catalog, to: url, appVersion: version, appBuild: build,
                                                  sourceMac: Host.current().localizedName ?? "Mac")
            }.value
            print("CatalogTransfer: exported \(result.info.photoCount) photos to \(url.path) (\(result.bytes) bytes, \(String(format: "%.2f", result.seconds)) s, \(result.writeMethod))")
            step = .exported(result)
        } catch {
            step = .failed(title: "Export Failed", message: String(describing: error))
        }
    }

    // MARK: - Import

    /// File > Import Catalog…: open panel, then validate + summary.
    func chooseImportFile(model: AppModel) {
        guard canStart(model: model) else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Catalog"
        panel.prompt = "Choose"
        panel.message = "Choose a Sloproom catalog export (.sloproomcatalog) or a Catalog.sqlite file. You'll see what it contains before anything is replaced."
        var types = [Self.catalogType]
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await inspect(url, model: model) }
    }

    func inspect(_ url: URL, model: AppModel) async {
        guard canStart(model: model) else { return }
        step = .working("Checking “\(url.lastPathComponent)”…")
        let staging = CatalogTransfer.workDirectory(for: model.catalog)
        let current = model.catalog
        do {
            let summary = try await Task.detached(priority: .userInitiated) { () throws -> ImportSummary in
                let candidate = try CatalogTransfer.stageImport(from: url, stagingDirectory: staging)
                let mounted = RootAccess.mountedVolumePaths()
                let rows = candidate.roots.map { RootRow(root: $0, status: RootAccess.status(of: $0, mounted: mounted)) }
                return ImportSummary(candidate: candidate, roots: rows, current: try? CatalogTransfer.info(of: current))
            }.value
            step = .summary(summary)
        } catch {
            step = .failed(title: "Can't Import Catalog", message: String(describing: error))
        }
    }

    /// "Replace Current Catalog" in the summary sheet.
    func replace(model: AppModel) async {
        guard case .summary(let summary) = step else { return }
        if let problem = blockingReason(model: model) {
            step = .failed(title: "Can't Replace the Catalog Now", message: problem)
            CatalogTransfer.removeDatabaseFiles(summary.candidate.stagedURL)
            return
        }
        let start = Date()
        step = .working("Closing the current catalog…")
        model.prepareForCatalogReplacement()
        PreviewJobs.shared.cancel()
        DevelopSession.flushPendingSaves()
        // Grid cells are gone; let preview loads already running for the old catalog finish
        // before its Previews directory is discarded.
        try? await Task.sleep(for: .milliseconds(800))
        step = .working("Backing up and replacing the catalog…")
        let old = model.catalog
        let candidate = summary.candidate
        do {
            let (catalog, backup) = try await Task.detached(priority: .userInitiated) {
                try CatalogTransfer.replaceCatalog(old, with: candidate)
            }.value
            activate(catalog, model: model, discardPreviews: true)
            let needsAttention = ((try? catalog.allRoots()) ?? []).filter { RootAccess.status(of: $0) != .granted }.count
            let info = (try? CatalogTransfer.info(of: catalog)) ?? candidate.info
            step = .imported(ImportOutcome(info: info, sourceName: candidate.sourceURL.lastPathComponent, backup: backup,
                                           needsAttention: needsAttention, seconds: Date().timeIntervalSince(start)))
            print("CatalogTransfer: imported \(info.photoCount) photos, \(info.folderCount) folders; backup \(backup.path); \(needsAttention) drives need attention; \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        } catch CatalogTransferError.replaceFailed(let why, let backup, let reopened) {
            if let reopened { activate(reopened, model: model, discardPreviews: false) }
            CatalogTransfer.removeDatabaseFiles(candidate.stagedURL)
            step = .failed(title: "Import Failed",
                           message: CatalogTransferError.replaceFailed(why, backup: backup, reopened: reopened).description)
        } catch {
            // Failed before the current catalog was closed (e.g. the backup): nothing changed.
            model.reloadFolders()
            model.reloadPhotos()
            CatalogTransfer.removeDatabaseFiles(candidate.stagedURL)
            step = .failed(title: "Import Failed", message: "\(error)\n\nYour current catalog was not changed.")
        }
    }

    /// Cancel in the summary / Done / OK.
    func dismiss() {
        if case .summary(let s) = step { CatalogTransfer.removeDatabaseFiles(s.candidate.stagedURL) }
        guard !isWorking else { return }
        step = nil
    }

    // MARK: - Helpers

    private func activate(_ catalog: Catalog, model: AppModel, discardPreviews: Bool) {
        SecurityScopeManager.shared.reset()
        if discardPreviews {
            CatalogTransfer.discardPreviewsDirectory(in: catalog.catalogDirectory)
            PreviewService.shared.discardAll()
        } else {
            PreviewService.shared.purgeMemoryCache()
        }
        model.replaceCatalog(with: catalog)
    }

    private func canStart(model: AppModel) -> Bool {
        if step != nil { NSSound.beep(); return false }
        if let problem = blockingReason(model: model) {
            step = .failed(title: "Not Now", message: problem)
            return false
        }
        return true
    }

    private func blockingReason(model: AppModel) -> String? {
        if ExportController.shared.phase == .exporting { return "Photos are being exported. Wait until the export has finished." }
        if model.presentedSheet != nil || ExportController.shared.isPresented { return "Close the open sheet first." }
        return nil
    }

    static var appVersion: (String, String) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "?", info["CFBundleVersion"] as? String ?? "?")
    }
}
