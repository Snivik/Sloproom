//
//  SloproomCommands.swift
//  sloproom
//
//  Menu bar. Single-letter shortcuts (P / U / X / G / D, 0-5) are real menu key equivalents
//  without modifiers; `TextInputGuard` makes them type the letter instead while a text field
//  is being edited.
//

import AppKit
import SwiftUI

struct SloproomCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { FolderActions.newFolderFromMenu(model: model) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Photos…") { model.presentedSheet = .importPhotos }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import Lightroom Catalog…") { model.presentedSheet = .importLightroom }
            Button("Add Folder in Place (Dev)…") { DevTools.addFolderInPlace(model: model) }
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if model.mode == .develop, let s = model.developSession { s.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Redo") {
                if model.mode == .develop, let s = model.developSession { s.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("Select All Photos") { model.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
        }

        CommandMenu("Photo") {
            letterButton("Pick", "p") { FlagActions.setFlag(.pick, model: model) }
            letterButton("Unflag", "u") { FlagActions.setFlag(.none, model: model) }
            letterButton("Reject", "x") { FlagActions.setFlag(.reject, model: model) }
            AutoAdvanceToggle()
            Divider()
            Menu("Set Rating") {
                ForEach(0...5, id: \.self) { stars in
                    letterButton(stars == 0 ? "None" : String(repeating: "★", count: stars),
                                 Character(String(stars))) { model.setRating(stars) }
                }
            }
            Divider()
            Button("Copy Settings") { model.copyDevelopSettings() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Settings") { model.pasteDevelopSettings() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            letterButton("Before / After", "\\") { model.developSession?.showBefore.toggle() }
        }

        CommandGroup(before: .sidebar) {
            letterButton("Library", "g") { model.mode = .library }
            letterButton("Develop", "d") { model.mode = .develop }
            Divider()
        }
    }

    /// A menu item with a no-modifier shortcut that yields to text editing.
    private func letterButton(_ title: String, _ key: Character, action: @escaping () -> Void) -> some View {
        Button(title) {
            if TextInputGuard.forwardIfEditing(String(key)) { return }
            action()
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
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
