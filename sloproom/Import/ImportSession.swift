//
//  ImportSession.swift
//  sloproom
//
//  State of the Import Photos sheet (MainActor): source selection + sandbox grants, progressive
//  scan (file list first, then metadata / duplicate flags in chunks), check state, options,
//  destination, and the running import. Engine work lives in ImportEngine.swift.
//

import AppKit
import Foundation
import Observation

/// Photos of one capture day in the grid.
struct ImportSection: Identifiable {
    var id: String
    var title: String
    var items: [ImportCandidate]
}

@Observable
final class ImportSession {
    let catalog: Catalog

    // MARK: Source
    private(set) var volumes: [ImportVolume] = []
    private(set) var recentFolder: RecentImportFolder? = ImportSources.recentFolder
    private(set) var sourceURL: URL?
    private(set) var sourceTitle = ""
    /// Volume id or recent-folder key of the selected source (for highlighting).
    private(set) var sourceID: String?

    // MARK: Scan
    private(set) var isScanning = false
    private(set) var scanStatus = ""
    private(set) var files: [ImportFile] = []
    private(set) var metadata: [String: PhotoMetadata] = [:]
    /// Primary file ids already in the catalog.
    private(set) var duplicates: Set<String> = []
    private(set) var unreadable: Set<String> = []
    private(set) var candidates: [ImportCandidate] = []
    private(set) var sections: [ImportSection] = []
    /// Everything is checked unless the user unchecked it (new candidates start checked).
    var unchecked: Set<String> = []

    // MARK: Options (remembered)
    var mode: ImportMode = ImportMode(rawValue: UserDefaults.standard.string(forKey: "import.mode") ?? "") ?? .copy {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "import.mode") }
    }
    var pattern: DestinationPattern = DestinationPattern(rawValue: UserDefaults.standard.string(forKey: "import.pattern") ?? "") ?? .yearAndDay {
        didSet { UserDefaults.standard.set(pattern.rawValue, forKey: "import.pattern") }
    }
    var pairSidecars: Bool = UserDefaults.standard.object(forKey: "import.pairSidecars") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pairSidecars, forKey: "import.pairSidecars")
            rebuildCandidates()
        }
    }
    var skipDuplicates: Bool = UserDefaults.standard.object(forKey: "import.skipDuplicates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skipDuplicates, forKey: "import.skipDuplicates") }
    }
    private(set) var destination: Root?
    /// Why the destination can't be used (missing, no write access), nil = fine / unchecked.
    private(set) var destinationProblem: String?
    var targetFolderID: Int64?
    var newFolderName = ""

    // MARK: Import
    private(set) var isImporting = false
    private(set) var progress = ImportProgress()
    var errorMessage: String?

    private var job: ImportJob?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(catalog: Catalog) {
        self.catalog = catalog
        // Remembered by path (root ids differ between catalogs).
        if let path = UserDefaults.standard.string(forKey: "import.destinationPath"),
           let root = (try? catalog.allRoots())?.first(where: { $0.path == path }) {
            setDestination(root)
        }
    }

    // MARK: - Derived

    func isIncluded(_ c: ImportCandidate) -> Bool {
        !unchecked.contains(c.id) && !(skipDuplicates && duplicates.contains(c.id))
    }
    func isLocked(_ c: ImportCandidate) -> Bool { skipDuplicates && duplicates.contains(c.id) }
    var included: [ImportCandidate] { candidates.filter(isIncluded) }

    var canImport: Bool {
        guard !isImporting, sourceURL != nil, !candidates.isEmpty, candidates.contains(where: isIncluded) else { return false }
        return mode == .addInPlace || (destination != nil && destinationProblem == nil)
    }

    /// Destination subfolders with photo counts for the included photos (copy mode).
    var plannedFolders: [(path: String, count: Int)] {
        guard pattern != .none else { return [] }
        let counts = Dictionary(grouping: included) { c in
            pattern.subpath(for: ImportScanner.date(of: c.primary, metadata: metadata[c.id]) ?? Date())
        }.mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted { $0.path < $1.path }
    }

    // MARK: - Sources

    func refreshVolumes() {
        volumes = ImportSources.volumes()
        if let id = sourceID, sourceURL != nil, id.hasPrefix("/"), !volumes.contains(where: { $0.id == id }) {
            clearSource() // the selected card was ejected
        }
    }

    /// On open: jump straight into a card we already have access to.
    func autoSelectCard() {
        guard sourceURL == nil, !isImporting,
              let card = volumes.first(where: { $0.hasDCIM && ImportSources.grantedURL(forKey: $0.bookmarkKey) != nil }) else { return }
        open(volume: card)
    }

    func open(volume: ImportVolume) {
        if let url = ImportSources.grantedURL(forKey: volume.bookmarkKey) {
            scan(url, title: volume.name, id: volume.id)
            return
        }
        // Sandbox: the user must grant access once; point the panel at the card.
        guard let url = runOpenPanel(at: volume.url, prompt: "Allow Access",
                                     message: "Select “\(volume.name)” and click Allow Access so Sloproom can read the card. You only need to do this once per card.") else { return }
        ImportSources.remember(url, key: volume.bookmarkKey)
        scan(url, title: volume.name, id: volume.id)
    }

    func openRecentFolder() {
        guard let recent = recentFolder else { return }
        if let url = ImportSources.grantedURL(forKey: recent.key) {
            scan(url, title: recent.name, id: recent.key)
        } else {
            chooseFolder(startingAt: URL(fileURLWithPath: recent.path))
        }
    }

    func chooseFolder(startingAt start: URL? = nil) {
        guard let url = runOpenPanel(at: start ?? sourceURL, prompt: "Choose",
                                     message: "Choose a folder or card to import photos from.") else { return }
        let key = ImportSources.key(forPickedFolder: url)
        ImportSources.remember(url, key: key)
        let recent = RecentImportFolder(name: url.lastPathComponent, path: url.path, key: key)
        ImportSources.recentFolder = recent
        recentFolder = recent
        let volume = volumes.first { ImportSources.key(forPickedFolder: $0.url) == key || $0.bookmarkKey == key }
        scan(url, title: volume?.name ?? url.lastPathComponent, id: volume?.id ?? key)
    }

    /// Scans a folder the app can already read (no panel). Used by DevScript / container paths.
    func open(folder url: URL) {
        scan(url, title: url.lastPathComponent, id: "folder:" + url.path)
    }

    /// Uses a folder the app can already write to as destination (no panel). DevScript.
    func setDestination(folder url: URL) throws {
        setDestination(try SecurityScopeManager.shared.registerRoot(url: url, in: catalog))
    }

    private func runOpenPanel(at directory: URL?, prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func clearSource() {
        cancelScan()
        sourceURL = nil
        sourceID = nil
        sourceTitle = ""
        files = []; metadata = [:]; duplicates = []; unreadable = []; unchecked = []
        rebuildCandidates()
    }

    // MARK: - Scan

    func rescan() {
        guard let url = sourceURL, let id = sourceID else { return }
        scan(url, title: sourceTitle, id: id)
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        isScanning = false
    }

    private func scan(_ url: URL, title: String, id: String) {
        cancelScan()
        let generation = scanGeneration
        sourceURL = url
        sourceTitle = title
        sourceID = id
        files = []; metadata = [:]; duplicates = []; unreadable = []; unchecked = []
        errorMessage = nil
        rebuildCandidates()
        isScanning = true
        scanStatus = "Looking for photos…"

        let catalog = catalog
        scanTask = Task.detached(priority: .userInitiated) { [self] in
            let index = (try? DuplicateIndex(catalog: catalog)) ?? DuplicateIndex()
            let found = ImportScanner.enumerate(url, isCancelled: { Task.isCancelled }) { count in
                Task { @MainActor in self.update(generation) { $0.scanStatus = "Found \(count) photos…" } }
            }
            if Task.isCancelled { return }
            await MainActor.run { self.update(generation) { $0.files = found; $0.rebuildCandidates() } }

            // Metadata + duplicate flags in chunks, so the grid fills in progressively.
            let chunkSize = 48
            for start in stride(from: 0, to: found.count, by: chunkSize) {
                if Task.isCancelled { return }
                let chunk = Array(found[start..<min(start + chunkSize, found.count)])
                let meta = ImportScanner.readMetadata(chunk)
                let dups = Set(chunk.filter { index.isDuplicate($0, metadata: meta[$0.id]) }.map(\.id))
                let bad = Set(chunk.map(\.id)).subtracting(meta.keys)
                let done = start + chunk.count
                await MainActor.run {
                    self.update(generation) { s in
                        s.metadata.merge(meta) { $1 }
                        s.duplicates.formUnion(dups)
                        s.unreadable.formUnion(bad)
                        s.scanStatus = "Reading \(done) of \(found.count)…"
                        s.rebuildCandidates()
                    }
                }
            }
            await MainActor.run { self.update(generation) { $0.isScanning = false; $0.scanStatus = "" } }
        }
    }

    /// Applies a scan result only if it belongs to the current scan.
    private func update(_ generation: Int, _ body: (ImportSession) -> Void) {
        guard generation == scanGeneration else { return }
        body(self)
    }

    private func rebuildCandidates() {
        let usable = unreadable.isEmpty ? files : files.filter { !unreadable.contains($0.id) }
        let cands = ImportScanner.candidates(from: usable, pairSidecars: pairSidecars)
        let cal = Calendar.current
        let dayFormat = Date.FormatStyle(date: .complete, time: .omitted)
        var byDay: [Date: [ImportCandidate]] = [:]
        var undated: [ImportCandidate] = []
        for c in cands {
            if let d = ImportScanner.date(of: c.primary, metadata: metadata[c.id]) {
                byDay[cal.startOfDay(for: d), default: []].append(c)
            } else {
                undated.append(c)
            }
        }
        var result = byDay.keys.sorted().map { day in
            ImportSection(id: "\(day.timeIntervalSince1970)", title: day.formatted(dayFormat),
                          items: byDay[day]!.sorted { $0.primary.fileName.localizedStandardCompare($1.primary.fileName) == .orderedAscending })
        }
        if !undated.isEmpty { result.append(ImportSection(id: "undated", title: "Unknown Date", items: undated)) }
        sections = result
        candidates = result.flatMap(\.items)
    }

    // MARK: - Check state

    func toggle(_ c: ImportCandidate) {
        guard !isLocked(c) else { return }
        if unchecked.contains(c.id) { unchecked.remove(c.id) } else { unchecked.insert(c.id) }
    }

    func checkAll() { unchecked.removeAll() }
    func uncheckAll() { unchecked = Set(candidates.map(\.id)) }

    /// Section header checkbox: checks all of the section unless all are already checked.
    func toggleSection(_ s: ImportSection) {
        let ids = s.items.filter { !isLocked($0) }.map(\.id)
        if ids.allSatisfy({ !unchecked.contains($0) }) { unchecked.formUnion(ids) } else { unchecked.subtract(ids) }
    }

    // MARK: - Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where imported photos are copied to (e.g. a folder on your photo drive)."
        panel.directoryURL = destination?.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            setDestination(try SecurityScopeManager.shared.registerRoot(url: url, in: catalog))
        } catch {
            errorMessage = "Can't use \(url.path): \(error)"
        }
    }

    private func setDestination(_ root: Root) {
        destination = root
        UserDefaults.standard.set(root.path, forKey: "import.destinationPath")
        destinationProblem = nil
        let catalog = catalog
        // Off-main: a sleeping external drive can take a while to answer.
        Task.detached(priority: .userInitiated) { [self] in
            SecurityScopeManager.shared.ensureAccess(forPath: root.path, rootID: root.id, catalog: catalog)
            let problem: String?
            if !FileManager.default.fileExists(atPath: root.path) {
                problem = "“\(root.path)” is not available. Connect the drive or choose another destination."
            } else {
                do { try ImportFiles.checkWriteAccess(root.url); problem = nil } catch { problem = "\(error)" }
            }
            await MainActor.run {
                guard self.destination?.id == root.id else { return }
                self.destinationProblem = problem
            }
        }
    }

    // MARK: - Import

    /// Starts the import. `onFinished` runs on main when photos were imported (also after a cancel).
    func startImport(onFinished: @escaping (ImportResult) -> Void) {
        guard canImport, let sourceURL else { return }
        let items = included
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = ImportOptions(mode: mode, destination: destination?.url, pattern: pattern,
                                    targetFolderID: targetFolderID, newFolderName: name.isEmpty ? nil : name)
        if mode == .addInPlace {
            // The photos stay on the source, so it must become a root (security-scoped bookmark).
            do { try SecurityScopeManager.shared.registerRoot(url: sourceURL, in: catalog) } catch {
                errorMessage = "Can't add \(sourceURL.path) to the catalog: \(error)"
                return
            }
        }
        cancelScan()
        errorMessage = nil
        isImporting = true
        progress = ImportProgress()
        let job = ImportJob()
        self.job = job
        let metadata = metadata
        let catalog = catalog
        Task.detached(priority: .userInitiated) { [self] in
            var lastUpdate = Date.distantPast
            do {
                let result = try job.run(items, metadata: metadata, options: options, catalog: catalog) { p in
                    let now = Date()
                    guard now.timeIntervalSince(lastUpdate) > 0.08 || p.currentFile == nil else { return }
                    lastUpdate = now
                    Task { @MainActor in if self.isImporting { self.progress = p } }
                }
                await MainActor.run { self.finish(result, onFinished: onFinished) }
                ImportJob.warmPreviews(photoIDs: result.photoIDs)
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    func cancelImport() { job?.cancel() }

    private func finish(_ result: ImportResult, onFinished: (ImportResult) -> Void) {
        isImporting = false
        job = nil
        if let stop = result.stopError {
            let done = result.photoIDs.count
            errorMessage = (done > 0 ? "Imported \(done) photos, then stopped. " : "") + stop.description
            rescan()
            return
        }
        if result.photoIDs.isEmpty {
            if !result.wasCancelled {
                errorMessage = result.failures.isEmpty ? "Nothing was imported." : result.failures.joined(separator: "\n")
            }
            rescan()
            return
        }
        onFinished(result)
    }

    private func fail(_ error: Error) {
        isImporting = false
        job = nil
        errorMessage = "\(error)"
    }
}
