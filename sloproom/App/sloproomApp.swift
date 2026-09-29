//
//  sloproomApp.swift
//  sloproom
//
//  Created by Alexander Troshchenko on 29/09/2026.
//

import SwiftUI

@main
struct sloproomApp: App {
    @State private var model = AppModel.makeDefault()

    var body: some Scene {
        Window("Sloproom", id: "main") {
            MainWindowView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            SloproomCommands(model: model)
            PreviewCommands(model: model)
            ExportCommands(model: model)
            CatalogTransferCommands(model: model)
        }

        Settings {
            SettingsRootView()
                .environment(model)
        }
    }
}

/// Settings window: Previews, Drives, Keyboard (the selected tab is `SettingsNavigation.shared.tab`
/// so menu items can open a specific tab).
struct SettingsRootView: View {
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            Tab("Previews", systemImage: "photo.stack", value: SettingsTab.previews) {
                PreviewSettingsView(showsDoneButton: false)
            }
            Tab("Drives", systemImage: "externaldrive", value: SettingsTab.drives) {
                ScrollView {
                    RootsAccessView()
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 520, minHeight: 280)
            }
            Tab("Keyboard", systemImage: "keyboard", value: SettingsTab.keyboard) {
                KeyboardSettingsView()
            }
        }
        .toolbarHelp([
            "Previews": "Preview sizes, quality, Develop render cache, cache size",
            "Drives": "Folders and drives Sloproom may read; grant access or relink",
            "Keyboard": "Keyboard shortcuts: view and change them",
        ])
    }
}
