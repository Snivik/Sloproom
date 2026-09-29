//
//  ImportPhotosSheet.swift
//  sloproom
//
//  File > Import Photos… (⇧⌘I). Lightroom-like: source (cards / folders) on the left, a checkable
//  thumbnail grid grouped by capture day in the middle, destination + options on the right,
//  import progress in the footer. State: ImportSession; engine: ImportEngine.
//

import AppKit
import Combine
import SwiftUI

struct ImportPhotosSheet: View {
    @Environment(AppModel.self) private var model
    @State private var session: ImportSession?

    var body: some View {
        Group {
            if let session {
                ImportPhotosContent(session: session)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 960, idealWidth: 1040, minHeight: 640, idealHeight: 720)
        .onAppear {
            if session == nil { session = ImportSession(catalog: model.catalog) }
        }
    }
}

private struct ImportPhotosContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ImportSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ImportSourceColumn(session: session)
                    .frame(width: 210)
                Divider()
                ImportGridColumn(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ImportOptionsColumn(session: session)
                    .frame(width: 270)
            }
            Divider()
            footer
        }
        .interactiveDismissDisabled(session.isImporting)
        .onAppear {
            session.refreshVolumes()
            session.autoSelectCard()
            #if DEBUG
            ImportDevCommands.attach(session, start: startImport)
            #endif
        }
        .onDisappear { session.cancelScan() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            session.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            session.refreshVolumes()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if session.isImporting {
                let p = session.progress
                ProgressView(value: p.fraction)
                    .frame(width: 220)
                VStack(alignment: .leading, spacing: 1) {
                    Text(progressLine(p)).font(.callout).monospacedDigit()
                    if let f = p.currentFile { Text(f).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button("Stop Import") { session.cancelImport() }
                    .keyboardShortcut(.cancelAction)
            } else {
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importTitle) { startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canImport)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var importTitle: String {
        let n = session.included.count
        let verb = session.mode == .copy ? "Import" : "Add"
        return n > 0 ? "\(verb) \(n) Photo\(n == 1 ? "" : "s")" : verb
    }

    private func progressLine(_ p: ImportProgress) -> String {
        var s = "\(p.filesDone) of \(p.filesTotal) files"
        if p.bytesTotal > 0 { s += " · \(bytes(p.bytesDone)) of \(bytes(p.bytesTotal))" }
        if let eta = p.eta, p.bytesTotal > 0 { s += " · " + remaining(eta) }
        return s
    }

    private func remaining(_ t: TimeInterval) -> String {
        t < 60 ? "\(max(1, Int(t.rounded()))) s left" : "\(Int((t / 60).rounded(.up))) min left"
    }

    private func startImport() {
        session.startImport { result in
            if let folderID = result.folderID {
                model.selectedSource = .folder(id: folderID, includeSubfolders: model.includeSubfolders)
            } else {
                model.selectedSource = .lastImport
            }
            model.mode = .library
            model.selection = []
            if !result.failures.isEmpty {
                model.errorMessage = "Imported \(result.photoIDs.count) photos, but some files failed:\n"
                    + result.failures.prefix(10).joined(separator: "\n")
            }
            dismiss()
        }
    }
}

fileprivate func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// MARK: - Source column

private struct ImportSourceColumn: View {
    @Bindable var session: ImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ImportColumnHeader("From")
            ForEach(session.volumes) { v in
                SourceRow(icon: v.hasDCIM ? "sdcard" : "externaldrive", title: v.name,
                          subtitle: v.hasDCIM ? "Camera card" : "Removable volume",
                          isSelected: session.sourceID == v.id) { session.open(volume: v) }
            }
            if session.volumes.isEmpty {
                Text("No cards detected. Insert a card or choose a folder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            if let recent = session.recentFolder, !recent.key.hasPrefix("volume:") {
                SourceRow(icon: "folder", title: recent.name, subtitle: recent.path,
                          isSelected: session.sourceID == recent.key) { session.openRecentFolder() }
            }
            Button {
                session.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Spacer()

            ImportColumnHeader("Mode")
            Picker("Mode", selection: $session.mode) {
                ForEach(ImportMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.horizontal, 8)
            Text(session.mode == .copy
                 ? "Copies the files, then adds the copies."
                 : "Adds the files where they are; nothing is copied.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .disabled(session.isImporting)
    }
}

private struct SourceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ImportColumnHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

// MARK: - Grid column

private struct ImportGridColumn: View {
    @Bindable var session: ImportSession
    private let columns = [GridItem(.adaptive(minimum: 142, maximum: 180), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.sourceURL == nil {
                placeholder("sdcard", "Choose a card or folder to import from.")
            } else if session.candidates.isEmpty {
                if session.isScanning {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(session.scanStatus).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder("photo.on.rectangle.angled", "No photos found in “\(session.sourceTitle)”.")
                }
            } else {
                grid
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.sourceURL == nil ? "Import Photos" : session.sourceTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if session.isScanning, !session.candidates.isEmpty {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Check All") { session.checkAll() }
            Button("Uncheck All") { session.uncheckAll() }
        }
        .controlSize(.small)
        .disabled(session.candidates.isEmpty || session.isImporting)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        guard session.sourceURL != nil else { return "Insert a camera card or choose a folder." }
        let all = session.candidates
        let chosen = session.included
        let size = chosen.reduce(Int64(0)) { $0 + $1.totalSize }
        var s = "\(chosen.count) of \(all.count) photos selected · \(bytes(size))"
        let dups = all.filter { session.duplicates.contains($0.id) }.count
        if dups > 0 { s += " · \(dups) already imported" }
        if session.isScanning { s += " · " + session.scanStatus }
        return s
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8, pinnedViews: [.sectionHeaders]) {
                ForEach(session.sections) { section in
                    Section {
                        ForEach(section.items) { c in
                            ImportCandidateCell(candidate: c,
                                                isIncluded: session.isIncluded(c),
                                                isDuplicate: session.duplicates.contains(c.id),
                                                isLocked: session.isLocked(c))
                                .onTapGesture { session.toggle(c) }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .padding(12)
        }
        .disabled(session.isImporting)
    }

    private func sectionHeader(_ s: ImportSection) -> some View {
        let selectable = s.items.filter { !session.isLocked($0) }
        let checked = selectable.filter(session.isIncluded).count
        return HStack(spacing: 8) {
            Button { session.toggleSection(s) } label: {
                Image(systemName: checked == 0 ? "square" : checked == selectable.count ? "checkmark.square.fill" : "minus.square.fill")
                    .foregroundStyle(checked == 0 ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(selectable.isEmpty)
            Text(s.title).font(.subheadline.weight(.semibold))
            Text("\(s.items.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportCandidateCell: View {
    let candidate: ImportCandidate
    let isIncluded: Bool
    let isDuplicate: Bool
    let isLocked: Bool

    var body: some View {
        VStack(spacing: 4) {
            ImportThumbnailView(url: candidate.primary.url)
                .frame(height: 100)
                .overlay(alignment: .topLeading) {
                    Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isIncluded ? Color.white : Color.secondary, isIncluded ? Color.accentColor : Color.clear)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background.opacity(isIncluded ? 0 : 0.7)))
                        .padding(2)
                }
            Text(candidate.primary.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                if candidate.sidecar != nil { badge("RAW+JPG", .secondary) }
                else if candidate.primary.isRAW { badge("RAW", .secondary) }
                if isDuplicate { badge("Imported", .orange) }
            }
            .frame(height: 14)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isIncluded ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
        .opacity(isLocked ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(isLocked ? "Already in the catalog (turn off “Don't import suspected duplicates” to import again)" : candidate.primary.url.path)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - Options column

private struct ImportOptionsColumn: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: ImportSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.mode == .copy { destinationSection } else { inPlaceNote }
                Divider()
                folderSection
                Divider()
                ImportColumnHeader("Options")
                Toggle("Don't import suspected duplicates", isOn: $session.skipDuplicates)
                    .padding(.horizontal, 8)
                Toggle("Treat JPEG next to RAW as sidecar", isOn: $session.pairSidecars)
                    .padding(.horizontal, 8)
                    .help("RAW+JPEG pairs are copied together, but only the RAW is added to the catalog.")
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .disabled(session.isImporting)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ImportColumnHeader("To")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                if let d = session.destination {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.displayName ?? d.url.lastPathComponent).lineLimit(1)
                        Text(d.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                } else {
                    Text("No destination").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(session.destination == nil ? "Choose…" : "Change…") { session.chooseDestination() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            if let problem = session.destinationProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            Picker("Organize", selection: $session.pattern) {
                ForEach(DestinationPattern.allCases) { Text($0.title).tag($0) }
            }
            .padding(.horizontal, 8)
            let planned = session.plannedFolders
            if !planned.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(planned.prefix(8), id: \.path) { f in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(f.path).lineLimit(1)
                            Spacer()
                            Text("\(f.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if planned.count > 8 { Text("+ \(planned.count - 8) more folders").foregroundStyle(.secondary) }
                }
                .font(.caption)
                .padding(.horizontal, 8)
            }
        }
    }

    private var inPlaceNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            ImportColumnHeader("To")
            Text("Photos stay where they are. The source folder is remembered so Sloproom can read it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ImportColumnHeader("Add to Folder")
            Picker("Folder", selection: $session.targetFolderID) {
                Text("None").tag(Int64?.none)
                ForEach(flatFolders, id: \.folder.id) { item in
                    Text(String(repeating: "\u{2003}", count: item.depth) + item.folder.name).tag(Int64?.some(item.folder.id))
                }
            }
            .labelsHidden()
            .padding(.horizontal, 8)
            TextField("New folder (optional)", text: $session.newFolderName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
            let name = session.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let parent = session.targetFolderID.flatMap { id in model.folders.first { $0.id == id }?.name }
                Text(parent.map { "Creates “\(name)” inside “\($0)”." } ?? "Creates the top-level folder “\(name)”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var flatFolders: [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ nodes: [FolderNode], _ depth: Int) {
            for n in nodes {
                out.append((n.folder, depth))
                walk(n.children, depth + 1)
            }
        }
        walk(model.folderTree, 0)
        return out
    }
}
