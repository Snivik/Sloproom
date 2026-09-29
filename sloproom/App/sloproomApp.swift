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
            TabView {
                Tab("Previews", systemImage: "photo.stack") {
                    PreviewSettingsView(showsDoneButton: false)
                }
                Tab("Drives", systemImage: "externaldrive") {
                    ScrollView {
                        RootsAccessView()
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 520, minHeight: 280)
                }
            }
            .environment(model)
        }
    }
}
