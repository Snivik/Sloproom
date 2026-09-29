//
//  LibraryKeyMonitor.swift
//  sloproom
//
//  Main-window key handling for the two menu commands the menu bar can't deliver (handlers
//  registered with the shortcut dispatcher, keys from the user's bindings — defaults ⌘A / D):
//  - Select All Photos (⌘A). Edit > Select All sends `selectAll:` to the responder chain,
//    which SwiftUI's focusable grid doesn't answer, and the menu consumes the key so
//    `.onKeyPress` never sees it.
//  - Develop (D). AppKit auto-adds Edit > "Start Dictation…" (fn-D) and menu matching ignores
//    fn, so a plain D starts dictation instead of reaching View > Develop.
//  The dispatcher sees key events before menu matching and yields whenever a text view is
//  first responder (rename field, search) or the key window is a sheet / panel / Settings.
//  Installed once on the main window (MainWindowView), together with the dispatcher itself.
//

import AppKit
import SwiftUI

extension View {
    func libraryKeyShortcuts(model: AppModel) -> some View {
        shortcutDispatcher(model: model)
            .shortcutHandlers { [model] in
                let inMainWindow: @MainActor (NSEvent) -> Bool = { $0.window === ShortcutDispatcher.shared.mainWindow }
                return [
                    ShortcutHandler(.selectAllPhotos, when: inMainWindow) { _ in model.selectAll() },
                    ShortcutHandler(.developMode, when: inMainWindow) { _ in model.mode = .develop },
                ]
            }
    }
}
