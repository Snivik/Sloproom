//
//  RootsAccessView.swift
//  sloproom
//
//  Reusable "Locate drives" list: every catalog root (or only those covering `paths`) with its
//  status (offline / needs access / access granted) and a "Grant Access…" button that opens an
//  open panel at that folder and stores a security-scoped bookmark for it. Picking a parent
//  folder (e.g. the whole drive) also works. Refreshes when drives mount/unmount.
//  Usable anywhere with an `AppModel` in the environment (Lightroom import, Settings…).
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
                    Label(row.status.title, systemImage: symbol(row.status))
                        .font(.callout)
                        .foregroundStyle(color(row.status))
                    Button(row.status == .granted ? "Change…" : "Grant Access…") { grant(row.root) }
                        .disabled(isOffline(row.status))
                        .help(isOffline(row.status) ? "Connect the drive first" : "Choose this folder (or its drive) to let Sloproom read the photos")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: Catalog.didChange, object: model.catalog)) { note in
            if Catalog.change(from: note) == .roots { reload() }
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

    private struct Row: Identifiable {
        var root: Root
        var status: RootAccessStatus
        var id: Int64 { root.id }
    }

    private func isOffline(_ s: RootAccessStatus) -> Bool {
        if case .offline = s { return true }
        return false
    }

    private func symbol(_ s: RootAccessStatus) -> String {
        switch s {
        case .offline: "bolt.horizontal.circle"
        case .needsAccess: "lock"
        case .granted: "checkmark.circle.fill"
        }
    }

    private func color(_ s: RootAccessStatus) -> Color {
        switch s {
        case .offline: .secondary
        case .needsAccess: .orange
        case .granted: .green
        }
    }
}
