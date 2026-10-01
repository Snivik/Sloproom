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
            ShortcutMenuButton(.undo) {
                if model.mode == .develop, let s = model.developSession { s.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            }
            ShortcutMenuButton(.redo) {
                if model.mode == .develop, let s = model.developSession { s.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
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
            KeyboardShortcutsMenuButton()
            Divider()
        }

        CommandGroup(before: .help) {
            KeyboardShortcutsMenuButton()
            Divider()
        }
    }

    @ViewBuilder private var photoMenu: some View {
        ShortcutMenuButton(.pick) { FlagActions.setFlag(.pick, model: model) }
        ShortcutMenuButton(.unflag) { FlagActions.setFlag(.none, model: model) }
        ShortcutMenuButton(.reject) { FlagActions.setFlag(.reject, model: model) }
        AutoAdvanceToggle()
        Divider()
        Menu("Set Rating") {
            ForEach(0...5, id: \.self) { stars in
                ShortcutMenuButton(.rating(stars), title: stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    model.setRating(stars)
                }
            }
        }
        Divider()
        ShortcutMenuButton(.copySettings) { model.copyDevelopSettings() }
        ShortcutMenuButton(.pasteSettings) { model.pasteDevelopSettings() }
        ShortcutMenuButton(.beforeAfter) { model.developSession?.showBefore.toggle() }
        Divider()
        ShortcutMenuButton(.createVirtualCopy) { VirtualCopyActions.createFromMenu(model: model) }   // VirtualCopies/
        Button("Rename Virtual Copy…") { VirtualCopyActions.requestRename(model.actionTargetIDs, model: model) }
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
