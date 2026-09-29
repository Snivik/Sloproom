//
//  ExportCommands.swift
//  sloproom
//
//  Entry points of the Export sheet:
//    - File > Export… (⇧⌘E): `ExportCommands(model:)` in the App scene's `.commands`.
//    - grid context menu: `ExportMenuButton(ids:model:)` ("Export N Photos…").
//    - the sheet itself: `.exportSheet(model:)` on the main window.
//  Targets are `model.actionTargetIDs` read when the item is chosen (Library selection, Develop's
//  current photo). The menu item is disabled through a focused scene value that the window
//  updates on selection changes (Commands aren't re-rendered from AppModel changes).
//

import SwiftUI

extension FocusedValues {
    /// Number of photos File > Export… would export (nil = no main window focused).
    @Entry var exportTargetCount: Int?
}

struct ExportCommands: Commands {
    let model: AppModel
    @FocusedValue(\.exportTargetCount) private var targetCount

    var body: some Commands {
        CommandGroup(after: .newItem) {   // after File > Import… items (SloproomCommands)
            Button("Export…") { ExportController.shared.present(ids: model.actionTargetIDs, model: model) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(targetCount == 0)
        }
    }
}

/// "Export N Photos…" for context menus.
struct ExportMenuButton: View {
    let ids: [Int64]
    let model: AppModel

    var body: some View {
        Button(ids.count == 1 ? "Export 1 Photo…" : "Export \(ids.count) Photos…") {
            ExportController.shared.present(ids: ids, model: model)
        }
        .disabled(ids.isEmpty)
    }
}

extension View {
    /// Presents the Export sheet and publishes the export target count for the menu bar.
    func exportSheet(model: AppModel) -> some View {
        modifier(ExportSheetModifier(model: model))
    }
}

private struct ExportSheetModifier: ViewModifier {
    let model: AppModel
    @Bindable private var controller = ExportController.shared

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.exportTargetCount, model.actionTargetIDs.count)
            .sheet(isPresented: $controller.isPresented, onDismiss: { controller.close() }) {
                ExportSheet(controller: controller)
            }
    }
}
