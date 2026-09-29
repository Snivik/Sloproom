//
//  ExportController.swift
//  sloproom
//
//  State of the Export sheet (MainActor): photos to export, destination folder (remembered as a
//  security-scoped bookmark, write-probed off-main), JPEG quality (remembered), the running
//  `ExportJob` and its result. Open it with `ExportController.shared.present(ids:model:)`.
//

import AppKit
import Foundation
import Observation

@Observable
final class ExportController {
    static let shared = ExportController()

    enum Phase { case idle, exporting, finished }

    private enum Keys {
        static let bookmark = "export.destinationBookmark"
        static let path = "export.destinationPath"
        static let quality = "export.quality"
    }

    // MARK: Sheet
    var isPresented = false
    private(set) var photoIDs: [Int64] = []

    // MARK: Options (remembered)
    private(set) var destination: URL?
    /// Why the destination can't be used (missing, no write access); nil = fine / unchecked.
    private(set) var destinationProblem: String?
    private(set) var isCheckingDestination = false
    var quality: Int = ExportController.storedQuality() {
        didSet { UserDefaults.standard.set(quality, forKey: Keys.quality) }
    }

    // MARK: Job
    private(set) var phase: Phase = .idle
    private(set) var progress = ExportProgress()
    private(set) var result: ExportResult?

    private var catalog: Catalog?
    private var settingsOverride: [Int64: EditSettings] = [:]
    private var job: ExportJob?
    /// The destination URL whose security scope we started (kept open until the destination changes).
    private var scopedURL: URL?
    /// The running write probe (DevScript awaits it).
    private(set) var probeTask: Task<Void, Never>?
    private var restored = false

    var canExport: Bool {
        phase != .exporting && !photoIDs.isEmpty && destination != nil && destinationProblem == nil && !isCheckingDestination
    }

    var title: String { photoIDs.count == 1 ? "Export 1 photo" : "Export \(photoIDs.count) photos" }

    var progressText: String {
        let current = min(progress.done + 1, max(progress.total, 1))
        return "Exporting \(current) of \(progress.total)…"
    }

    // MARK: - Presenting

    /// Opens the sheet for `ids` (Library selection / Develop's current photo). Beeps when empty.
    func present(ids: [Int64], model: AppModel) {
        if phase == .exporting { isPresented = true; return }
        guard !ids.isEmpty else { NSSound.beep(); return }
        catalog = model.catalog
        photoIDs = ids
        // Develop: use the session's current settings (its save to the catalog is asynchronous).
        settingsOverride = [:]
        if let session = model.developSession, ids.contains(session.photo.id) {
            session.saveNow()
            settingsOverride[session.photo.id] = session.settings
        }
        phase = .idle
        result = nil
        progress = ExportProgress(total: ids.count)
        if !restored { restored = true; restoreDestination() } else if let destination { probe(destination) }
        isPresented = true
    }

    func close() {
        guard phase != .exporting else { return }
        isPresented = false
        if phase == .finished { phase = .idle; result = nil }
    }

    // MARK: - Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder exported JPEGs are saved to."
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestination(url)
    }

    /// Uses `url` as destination and remembers it (bookmark while the panel's grant is valid).
    func setDestination(_ url: URL) {
        restored = true
        let bookmark = try? SecurityScope.makeBookmark(for: url)
        let defaults = UserDefaults.standard
        if let bookmark { defaults.set(bookmark, forKey: Keys.bookmark) } else { defaults.removeObject(forKey: Keys.bookmark) }
        defaults.set(url.path, forKey: Keys.path)
        use(bookmark.flatMap(startAccess) ?? url)
    }

    private func restoreDestination() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.bookmark), let url = startAccess(data) {
            use(url)
        } else if let path = defaults.string(forKey: Keys.path) {
            use(URL(fileURLWithPath: path, isDirectory: true)) // e.g. inside the container: no bookmark needed
        }
    }

    /// Resolves a bookmark and starts its security scope (stopping the previous destination's).
    private func startAccess(_ data: Data) -> URL? {
        guard let resolved = try? SecurityScope.resolveBookmark(data) else { return nil }
        let url = resolved.url
        if scopedURL?.path == url.path { return scopedURL }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        if resolved.isStale, let fresh = try? SecurityScope.makeBookmark(for: url) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
        return url
    }

    private func use(_ url: URL) {
        destination = url
        probe(url)
    }

    /// Write-probes the destination off-main (a sleeping external drive can take a while).
    private func probe(_ url: URL) {
        destinationProblem = nil
        isCheckingDestination = true
        probeTask = Task { [weak self] in
            let problem = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try ExportFiles.checkWriteAccess(url); return nil } catch { return "\(error)" }
            }.value
            guard let self, self.destination == url else { return }
            self.destinationProblem = problem
            self.isCheckingDestination = false
        }
    }

    // MARK: - Export

    func start() {
        guard canExport, let catalog, let destination else { return }
        let job = ExportJob(catalog: catalog, photoIDs: photoIDs,
                            options: ExportOptions(destination: destination, quality: quality),
                            settingsOverride: settingsOverride)
        self.job = job
        phase = .exporting
        result = nil
        progress = ExportProgress(total: photoIDs.count)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                job.run { p in Task { @MainActor in ExportController.shared.update(p) } }
            }.value
            self.job = nil
            self.result = result
            self.progress.done = max(self.progress.done, result.exported.count + result.skipped.count)
            self.phase = .finished
            if let error = result.stopError, case .noWriteAccess = error { self.destinationProblem = error.description }
        }
    }

    private func update(_ p: ExportProgress) {
        guard phase == .exporting, p.done >= progress.done else { return }
        progress = p
    }

    func cancel() { job?.cancel() }

    func showInFinder() {
        guard let result else { return }
        let urls = result.exported.map(\.url)
        if urls.isEmpty, let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private static func storedQuality() -> Int {
        guard let q = UserDefaults.standard.object(forKey: Keys.quality) as? Int else { return 85 }
        return min(max(q, 0), 100)
    }
}
