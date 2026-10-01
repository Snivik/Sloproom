//
//  ExportCommands.swift
//  sloproom
//
//  Entry points of the Export sheet:
//    - File > Export… (⇧⌘E by default, ShortcutAction.exportPhotos): `ExportCommands(model:)` in the App scene's `.commands`.
//    - context menus: the photo actions registry's `exportJPEG` ("Export N Photos…", Actions/).
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
            ShortcutMenuButton(.exportPhotos) { ExportController.shared.present(ids: model.actionTargetIDs, model: model) }
                .disabled(targetCount == 0)
        }
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
