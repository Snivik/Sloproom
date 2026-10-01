//
//  SloproomCommands.swift
//  sloproom
//
//  Menu bar. Items with a shortcut are `ShortcutMenuButton`s: the key comes from the user's
//  bindings (ShortcutStore; Settings > Keyboard). Single-letter shortcuts (P / U / X / G / D,
//  0-5) are real menu key equivalents without modifiers; `TextInputGuard` makes them type the
//  letter instead while a text field is being edited.
//

import AppKit
import SwiftUI

struct SloproomCommands: Commands {
    let model: AppModel
    /// Bumped by ShortcutStore on every change: Commands re-render on AppStorage changes (not on
    /// Observable changes), so SwiftUI's own menu model follows the bindings. SwiftUI doesn't
    /// push a changed key equivalent into an existing NSMenuItem though; `ShortcutMenuSync`
    /// patches the items.
    @AppStorage(ShortcutStore.revisionKey) private var shortcutRevision = 0
    /// Number of action targets (Export's focused scene value): enables the Photo menu's
    /// single / multi actions without re-rendering Commands from AppModel.
    @FocusedValue(\.exportTargetCount) private var targetCount

    var body: some Commands {
        let _ = shortcutRevision
        CommandGroup(after: .newItem) {
            ShortcutMenuButton(.newFolder) { FolderActions.newFolderFromMenu(model: model) }
            Divider()
            ShortcutMenuButton(.importPhotos) { model.presentedSheet = .importPhotos }
            ShortcutMenuButton(.importLightroomCatalog) { model.presentedSheet = .importLightroom }
            Button("Add Folder in Place (Dev)…") { DevTools.addFolderInPlace(model: model) }
        }

        CommandGroup(replacing: .undoRedo) {
            // Develop session steps and bulk-edit steps (Actions/BulkEditor.swift), newest first;
            // otherwise the responder chain as before.
            ShortcutMenuButton(.undo) { BulkEditUndo.shared.undo(model: model) }
            ShortcutMenuButton(.redo) { BulkEditUndo.shared.redo(model: model) }
        }

        CommandGroup(after: .textEditing) {
            ShortcutMenuButton(.selectAllPhotos) { model.selectAll() }
        }

        CommandMenu("Photo") {
            photoMenu
        }

        CommandGroup(before: .sidebar) {
            ShortcutMenuButton(.libraryMode) { model.mode = .library }
            ShortcutMenuButton(.developMode) { model.mode = .develop }
            Divider()
            ShortcutMenuButton(.toggleSidebar) { DevelopPanels.shared.toggleSidebar(in: model.mode) }
            Divider()
            KeyboardShortcutsMenuButton()
            Divider()
        }

        CommandGroup(before: .help) {
            KeyboardShortcutsMenuButton()
            Divider()
        }
    }

    /// Built from the photo actions registry (Actions/PhotoActionMenus.swift).
    private var photoMenu: some View {
        PhotoMenuBarItems(model: model, targetCount: targetCount)
    }
}

/// If a text field/view is first responder, types `text` into it and returns true.
/// Menu key equivalents are matched before the field editor sees plain letters, so without
/// this, typing "p" in a search field would flag the photo instead.
enum TextInputGuard {
    static func forwardIfEditing(_ text: String) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable else { return false }
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }

    static var isEditingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable ?? false
    }
}
