//
//  LightroomImportSheet.swift
//  sloproom
//
//  File > Import Lightroom Catalog… (`SheetKind.importLightroom`). Imports the STRUCTURE of a
//  Lightroom Classic catalog: collection sets + collections → nested folders, photos (by path,
//  files stay where they are), pick/reject flags, star ratings. Develop edits are not imported.
//
//  Flow: choose .lrcat → (copy + read off-main) → summary / options / tree preview → import
//  (off-main, progress, cancel) → result + "Locate drives" (`RootsAccessView`).
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class LightroomImportModel {
    enum Phase: Equatable {
        case choose
        case loading
        case preview
        case importing
        case done
        case failed(String)
    }

    let catalog: Catalog
    private(set) var phase: Phase = .choose
    private(set) var snapshot: LightroomCatalogSnapshot?
    private(set) var plan: LightroomImportPlan?
    var options = LightroomImportOptions() { didSet { if options != oldValue { replan() } } }
    private(set) var progress = LightroomImportProgress(fraction: 0, message: "")
    private(set) var result: LightroomImportResult?
    /// Shown on the preview after a cancelled import.
    private(set) var notice: String?
    /// Online status of the Lightroom root folders (by LR root id).
    private(set) var rootsOnline: [Int64: Bool] = [:]
    private var task: Task<Void, Never>?

    init(catalog: Catalog) {
        self.catalog = catalog
    }

    func chooseCatalog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "lrcat") ?? .data]
        panel.prompt = "Choose"
        panel.message = "Choose a Lightroom Classic catalog (.lrcat). It is copied and only read, never changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    /// Copies + reads the catalog off-main. `thenImport` starts the import right away (dev script).
    func load(_ url: URL, thenImport: Bool = false) {
        task?.cancel()
        phase = .loading
        notice = nil
        task = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Result { try LightroomCatalogReader.load(copying: url) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch loaded {
            case .success(let snapshot):
                self.snapshot = snapshot
                let mounted = RootAccess.mountedVolumePaths()
                self.rootsOnline = Dictionary(uniqueKeysWithValues: snapshot.roots.map { ($0.id, RootAccess.isOnline($0.path, mounted: mounted)) })
                self.replan()
                self.phase = .preview
                if thenImport { self.startImport() }
            case .failure(let error):
                self.phase = .failed(String(describing: error))
            }
        }
    }

    private func replan() {
        guard let snapshot else { plan = nil; return }
        plan = LightroomImportPlan(snapshot: snapshot, options: options)
    }

    func startImport() {
        guard let plan, phase == .preview else { return }
        phase = .importing
        notice = nil
        progress = LightroomImportProgress(fraction: 0, message: "Starting…")
        let catalog = catalog
        let model = self
        let work = Task.detached(priority: .userInitiated) {
            try catalog.importLightroom(plan) { p in
                Task { @MainActor in if model.phase == .importing { model.progress = p } }
            }
        }
        task = Task {
            let outcome = await withTaskCancellationHandler {
                await work.result
            } onCancel: {
                work.cancel()
            }
            switch outcome {
            case .success(let result):
                model.result = result
                model.phase = .done
            case .failure(let error) where error is CancellationError:
                model.notice = "Import cancelled. Photos added so far are kept; importing again finishes the job without duplicates."
                model.phase = .preview
            case .failure(let error):
                model.phase = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

struct LightroomImportSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: LightroomImportModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .frame(width: 640)
        .onAppear {
            guard model == nil else { return }
            let m = LightroomImportModel(catalog: appModel.catalog)
            model = m
            #if DEBUG
            if let request = LightroomImportDev.takePendingRequest() { m.load(request.url, thenImport: request.autoImport) }
            #endif
        }
        .onDisappear { model?.cancel() }
    }

    @ViewBuilder
    private func content(_ model: LightroomImportModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Lightroom Catalog").font(.title2.bold())
                if let name = model.snapshot?.catalogName {
                    Text(name).foregroundStyle(.secondary)
                }
            }

            switch model.phase {
            case .choose:
                chooseView(model)
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading catalog…")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                footer { Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction).help("Stop reading and close (Esc)") }
            case .preview:
                if let plan = model.plan { previewView(model, plan: plan, options: $model.options) }
            case .importing:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: model.progress.fraction)
                    Text(model.progress.message).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                footer { Button("Cancel Import") { model.cancel() }.keyboardShortcut(.cancelAction).help("Stop the import (Esc)") }
            case .done:
                if let result = model.result, let plan = model.plan { doneView(result: result, plan: plan) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                footer {
                    Button("Choose Another…") { model.chooseCatalog() }.help("Pick a different Lightroom catalog (.lrcat)")
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).help("Close (Esc)")
                }
            }
        }
        .padding(20)
    }

    // MARK: - Phases

    private func chooseView(_ model: LightroomImportModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brings over your Lightroom Classic collection sets and collections as folders, with every photo, its pick/reject flag and star rating. Files stay where they are; Develop edits are not imported.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The catalog is copied and only read — Lightroom's file is never changed. Quit Lightroom first so its latest changes are saved into the catalog.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            footer {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).help("Close (Esc)")
                Button("Choose Catalog…") { model.chooseCatalog() }.keyboardShortcut(.defaultAction)
                    .help("Pick a Lightroom Classic catalog (.lrcat) to preview what will be imported")
            }
        }
    }

    private func previewView(_ model: LightroomImportModel, plan: LightroomImportPlan, options: Binding<LightroomImportOptions>) -> some View {
        let snapshot = plan.snapshot
        let quick = snapshot.collections(of: .quick).first
        return VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    stat(snapshot.photoCount, "photos")
                    stat(snapshot.collections(of: .set).count, "collection sets")
                    stat(snapshot.collections(of: .collection).count, "collections")
                    stat(snapshot.collections(of: .smart).count, "smart collections")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if !plan.skippedSmartCollections.isEmpty {
                    note("Smart collections are skipped: \(plan.skippedSmartCollections.joined(separator: ", ")).")
                }
                if !plan.skippedEmptySets.isEmpty {
                    note("Sets without regular collections are skipped: \(plan.skippedEmptySets.joined(separator: ", ")).")
                }
                if snapshot.videoCount > 0 {
                    note("\(snapshot.videoCount.formatted()) videos \(options.wrappedValue.includeVideos ? "are included" : "are skipped").")
                }
                if snapshot.virtualCopyCount > 0 {
                    note("\(snapshot.virtualCopyCount.formatted()) virtual copies are merged into their master photos.")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Root folders").font(.headline)
                ForEach(snapshot.roots) { root in
                    let online = model.rootsOnline[root.id] ?? false
                    HStack(spacing: 6) {
                        Image(systemName: online ? "externaldrive.fill" : "externaldrive")
                            .foregroundStyle(online ? .green : .secondary)
                        Text(root.path)
                        Text(online ? "Online" : "Offline").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if snapshot.roots.contains(where: { !(model.rootsOnline[$0.id] ?? false) }) {
                    note("Offline drives are fine: photos are added now and appear once you connect the drive and grant access.")
                }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Options").font(.headline)
                    Picker("Photos", selection: options.scope) {
                        Text("All photos in catalog").tag(LightroomImportOptions.PhotoScope.all)
                            .help("Every photo of the Lightroom catalog, also those in no collection")
                        Text("Only photos in collections").tag(LightroomImportOptions.PhotoScope.inCollections)
                            .help("Only photos that are in at least one collection")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .help("Import every photo of the catalog, or only those in collections")
                    Toggle("Import pick / reject flags", isOn: options.importFlags)
                        .help("Copy Lightroom's pick / reject flags")
                    Toggle("Import star ratings", isOn: options.importRatings)
                        .help("Copy Lightroom's star ratings")
                    if snapshot.videoCount > 0 {
                        Toggle("Include videos", isOn: options.includeVideos)
                            .help("Also add the catalog's videos")
                    }
                    if let quick, !quick.imageIDs.isEmpty {
                        Toggle("Include Quick Collection (\(quick.imageIDs.count))", isOn: options.includeQuickCollection)
                            .help("Also create a folder for Lightroom's Quick Collection")
                    }
                    Toggle("Put everything in a new folder:", isOn: options.createContainerFolder)
                        .help("Create the imported folders inside one new top-level folder")
                    TextField("Folder name", text: options.containerName)
                        .help("Name of the new top-level folder")
                        .disabled(!options.wrappedValue.createContainerFolder)
                        .frame(maxWidth: 200)
                        .padding(.leading, 20)
                }
                .frame(width: 250, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Folders to create").font(.headline)
                    List {
                        let container = plan.options.createContainerFolder && !plan.tree.isEmpty
                        if container {
                            treeRow(name: containerName(plan), isSet: true, count: plan.photosInFoldersCount)
                        }
                        OutlineGroup(plan.tree, children: \.childrenOrNil) { node in
                            treeRow(name: node.name, isSet: node.isSet, count: node.subtreePhotoCount)
                                .padding(.leading, container ? 16 : 0)
                        }
                    }
                    .listStyle(.bordered)
                    .alternatingRowBackgrounds()
                    .frame(height: 220)
                }
            }

            if let notice = model.notice {
                Label(notice, systemImage: "info.circle").font(.callout)
            }

            HStack {
                Button("Choose Another…") { model.chooseCatalog() }
                    .help("Pick a different Lightroom catalog (.lrcat)")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).help("Close without importing (Esc)")
                Button("Import \(plan.photos.count.formatted()) Photos") { model.startImport() }
                    .keyboardShortcut(.defaultAction)
                    .help("Add the photos and folders to the catalog (Return); files are not copied")
                    .disabled(options.wrappedValue.createContainerFolder
                              && options.wrappedValue.containerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func doneView(result: LightroomImportResult, plan: LightroomImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import complete", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(result.photosAdded.formatted()) photos added"
                     + (result.photosExisting > 0 ? ", \(result.photosExisting.formatted()) already in the catalog" : "") + ".")
                Text("\(result.foldersCreated.formatted()) folders created"
                     + (result.foldersReused > 0 ? ", \(result.foldersReused.formatted()) already existed" : "")
                     + "; \(result.membershipsAdded.formatted()) photos placed in folders.")
                Text(String(format: "Took %.1f s.", result.duration)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Locate drives").font(.headline)
                Text("Sloproom can only read photos on folders or drives you grant access to. Connect each drive and grant access once; it is remembered.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RootsAccessView(paths: plan.snapshot.roots.map(\.path))
                    .padding(.top, 4)
            }
            footer {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).help("Close (Return)")
            }
        }
    }

    // MARK: - Pieces

    private func containerName(_ plan: LightroomImportPlan) -> String {
        let name = plan.options.containerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Lightroom" : name
    }

    private func treeRow(name: String, isSet: Bool, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isSet ? "folder" : "rectangle.stack").foregroundStyle(.secondary)
            Text(name).lineLimit(1)
            Spacer()
            Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}
