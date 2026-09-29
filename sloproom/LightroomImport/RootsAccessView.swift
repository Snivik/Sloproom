//
//  RootsAccessView.swift
//  sloproom
//
//  Reusable "Locate drives" list: every catalog root (or only those covering `paths`) with its
//  status (offline / needs access / access granted), a "Grant Access…" button that opens an
//  open panel at that folder and stores a security-scoped bookmark for it (picking a parent
//  folder, e.g. the whole drive, also works), and "Relink…" to point the root at a DIFFERENT
//  folder (drive renamed, catalog imported from another Mac): samples the root's photos under the
//  picked folder (warns below 80% found), then rewrites the root + photo paths in one transaction.
//  Refreshes when drives mount/unmount, roots change or the catalog is replaced.
//  Usable anywhere with an `AppModel` in the environment (Lightroom import, Settings > Drives,
//  Import Catalog result).
//

import AppKit
import Combine
import SwiftUI

struct RootsAccessView: View {
    /// Only show roots equal to / containing these paths (nil = all roots).
    var paths: [String]? = nil

    @Environment(AppModel.self) private var model
    @State private var rows: [Row] = []
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pendingRelink: PendingRelink?
    @State private var checkingRootID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("No folders or drives yet.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: RootAccess.volumeName(for: row.root.path) == nil ? "folder" : "externaldrive")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.root.displayName ?? row.root.url.lastPathComponent).lineLimit(1)
                        Text(row.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Label(row.status.title, systemImage: Self.symbol(row.status))
                        .font(.callout)
                        .foregroundStyle(Self.color(row.status))
                    Button(row.status == .granted ? "Change…" : "Grant Access…") { grant(row.root) }
                        .disabled(isOffline(row.status))
                        .help(isOffline(row.status) ? "Connect the drive first" : "Choose this folder (or its drive) to let Sloproom read the photos")
                    if checkingRootID == row.root.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Relink…") { chooseRelinkFolder(row.root) }
                            .help("The photos are now at a different location (drive renamed, or another Mac): choose the folder that contains them")
                    }
                }
            }
            if let infoMessage {
                Text(infoMessage).font(.callout).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: ObjectIdentifier(model.catalog)) { reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: Catalog.didChange)) { note in
            if (note.object as AnyObject?) === model.catalog, Catalog.change(from: note) == .roots { reload() }
        }
        .alert(pendingRelink?.title ?? "", isPresented: Binding(
            get: { pendingRelink != nil },
            set: { if !$0 { pendingRelink = nil } }
        ), presenting: pendingRelink) { pending in
            Button("Relink Anyway") { performRelink(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    private func reload() {
        let mounted = RootAccess.mountedVolumePaths()
        do {
            rows = try RootAccess.roots(covering: paths, in: model.catalog).map { Row(root: $0, status: RootAccess.status(of: $0, mounted: mounted)) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func grant(_ root: Root) {
        errorMessage = nil
        infoMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"
        panel.message = "Choose “\(root.path)” (or the drive it is on) so Sloproom can read its photos."
        let fm = FileManager.default
        let start = [root.path, RootAccess.volumePath(for: root.path), "/Volumes"].first { fm.fileExists(atPath: $0) }
        panel.directoryURL = start.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RootAccess.grant(root, pickedURL: url, catalog: model.catalog)
        } catch {
            errorMessage = String(describing: error)
        }
        reload()
    }

    // MARK: - Relink

    private func chooseRelinkFolder(_ root: Root) {
        errorMessage = nil
        infoMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Relink"
        panel.message = "Choose the folder that now contains the photos of “\(root.path)” (with the same subfolders inside)."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Right after the panel returns, while its implicit access is valid.
        let bookmark = try? SecurityScope.makeBookmark(for: url)
        Task { await checkAndRelink(root, to: url, bookmark: bookmark) }
    }

    /// Samples the root's photos under `url`; relinks right away when ≥ 80% exist, otherwise asks.
    private func checkAndRelink(_ root: Root, to url: URL, bookmark: Data?) async {
        checkingRootID = root.id
        let catalog = model.catalog
        let check: RelinkCheck
        do {
            check = try await Task.detached(priority: .userInitiated) { try catalog.relinkCheck(root: root, newPath: url.path) }.value
        } catch {
            checkingRootID = nil
            errorMessage = String(describing: error)
            return
        }
        print("RootsAccessView: relink check \(root.path) → \(url.path): \(check.found)/\(check.sampled) found")
        let pending = PendingRelink(root: root, url: url, bookmark: bookmark, check: check)
        if check.looksRight { performRelink(pending) } else { checkingRootID = nil; pendingRelink = pending }
    }

    private func performRelink(_ p: PendingRelink) {
        pendingRelink = nil
        checkingRootID = p.root.id
        Task {
            defer { checkingRootID = nil }
            do {
                let result = try await Self.relink(p.root, to: p.url, bookmark: p.bookmark, model: model)
                infoMessage = "Relinked \(result.photoIDs.count.formatted()) photos to “\(result.newPath)”."
            } catch {
                errorMessage = String(describing: error)
            }
            reload()
        }
    }

    /// Relinks (off the main thread) and refreshes the app: photos reload now with their new
    /// paths, then their thumbnails retry (those that were offline under the old path).
    @discardableResult
    static func relink(_ root: Root, to url: URL, bookmark: Data?, model: AppModel) async throws -> RelinkResult {
        let catalog = model.catalog
        let result = try await Task.detached(priority: .userInitiated) {
            try RootAccess.relink(root, to: url, bookmark: bookmark, catalog: catalog)
        }.value
        model.reloadPhotos()
        PreviewJobs.notifyChanged(Set(result.photoIDs))
        return result
    }

    private struct PendingRelink: Identifiable {
        var root: Root
        var url: URL
        var bookmark: Data?
        var check: RelinkCheck
        var id: Int64 { root.id }
        var title: String { "Relink “\(root.displayName ?? root.url.lastPathComponent)” to “\(url.lastPathComponent)”?" }
        var message: String {
            let examples = check.missingExamples.prefix(2).map { "• " + $0 }.joined(separator: "\n")
            if check.sampled == 0 { return "This drive has no photos in the catalog." }
            return "Only \(check.found) of \(check.sampled) sampled photos were found in “\(url.path)” at the same relative paths. "
                + "Photos that aren't there will show as offline.\n\nNot found, e.g.:\n\(examples)"
        }
    }

    private struct Row: Identifiable {
        var root: Root
        var status: RootAccessStatus
        var id: Int64 { root.id }
    }

    private func isOffline(_ s: RootAccessStatus) -> Bool {
        if case .offline = s { return true }
        return false
    }

    static func symbol(_ s: RootAccessStatus) -> String {
        switch s {
        case .offline: "bolt.horizontal.circle"
        case .needsAccess: "lock"
        case .granted: "checkmark.circle.fill"
        }
    }

    static func color(_ s: RootAccessStatus) -> Color {
        switch s {
        case .offline: .secondary
        case .needsAccess: .orange
        case .granted: .green
        }
    }
}
