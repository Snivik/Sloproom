//
//  MainWindowView.swift
//  sloproom
//

import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    private var store: ShortcutStore { .shared }

    var body: some View {
        @Bindable var model = model
        // Folder sidebar visibility per mode (read here so toggles re-render; see DevelopPanels).
        let _ = DevelopPanels.shared.isSidebarHidden(in: model.mode)
        NavigationSplitView(columnVisibility: DevelopPanels.shared.columnVisibility(model: model)) {
            SidebarView()
                .id(ObjectIdentifier(model.catalog))   // fresh sidebar state after Import Catalog
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            switch model.mode {
            case .library: LibraryGridView()
            case .develop: DevelopView()
            }
        }
        .navigationTitle(title)
        .libraryKeyShortcuts(model: model)
        .fullScreenPreviewShortcut(model: model)
        .exportSheet(model: model)
        .catalogTransferSheet(model: model)
        .virtualCopySupport(model: model)   // Rename Virtual Copy alert (VirtualCopies/)
        .photoActionSupport(model: model)   // bulk sheets, confirmations, progress (Actions/)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .segmentHelp([store.help("Library: browse, flag and organize", .libraryMode),
                              store.help("Develop: edit the photo", .developMode)])
            }
            // Library shows the same filter in GridFilterBar; in Develop it filters the filmstrip.
            if model.mode == .develop {
                ToolbarItem {
                    Picker("Flag Filter", selection: $model.filter.flag) {
                        ForEach(FlagFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Show filmstrip photos by flag")
                }
                ToolbarItem {
                    PhotoActionsToolbarMenu(model: model)   // Actions/: every photo action in Develop
                }
            }
            ToolbarItem {
                PreviewActivityView()
            }
            ToolbarItem {
                Button { model.presentedSheet = .importPhotos } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help(store.help("Import Photos…", .importPhotos))
            }
        }
        .toolbarHelp([
            "com.apple.SwiftUI.navigationSplitView.toggleSidebar": store.help("Show / Hide Folders", .toggleSidebar),
            "Mode": "Library / Develop",
            "Flag Filter": "Show filmstrip photos by flag",
            "Photo Actions": PhotoActionsToolbarMenu.help(model),
            "Import": store.help("Import Photos…", .importPhotos),
        ])
        .sheet(item: $model.presentedSheet) { kind in
            switch kind {
            case .importPhotos: ImportPhotosSheet()
            case .importLightroom: LightroomImportSheet()
            case .previewSettings: PreviewSettingsView()
            }
        }
        #if DEBUG
        .task { DevScript.runIfRequested(model: model); DevScript.listenIfRequested(model: model) }
        #endif
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var title: String {
        switch model.selectedSource {
        case .all: "All Photographs"
        case .lastImport: "Previous Import"
        case .folder(let id, _): model.folders.first { $0.id == id }?.name ?? "Folder"
        }
    }
}
