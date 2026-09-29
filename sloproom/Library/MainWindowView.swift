//
//  MainWindowView.swift
//  sloproom
//

import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: DevelopPanels.shared.columnVisibility(mode: model.mode)) {
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
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
            }
            ToolbarItem {
                PreviewActivityView()
            }
            ToolbarItem {
                Button { model.presentedSheet = .importPhotos } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import Photos… (⇧⌘I)")
            }
        }
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
