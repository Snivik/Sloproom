//
//  LibraryKeyMonitor.swift
//  sloproom
//
//  Window-level key handling for the two shortcuts the menu bar can't deliver:
//  - ⌘A = select all photos (Library). Edit > Select All sends `selectAll:` to the responder
//    chain, which SwiftUI's focusable grid doesn't answer, and the menu consumes the key so
//    `.onKeyPress` never sees it.
//  - D = Develop. AppKit auto-adds Edit > "Start Dictation…" (fn-D) and menu matching ignores
//    fn, so a plain D starts dictation instead of reaching View > Develop.
//  A local monitor sees key events before menu matching. It yields whenever a text view is
//  first responder (rename field, search) or the key window is a sheet / panel.
//  Installed once on the main window (MainWindowView).
//

import AppKit
import SwiftUI

extension View {
    func libraryKeyShortcuts(model: AppModel) -> some View {
        modifier(LibraryKeyShortcuts(model: model))
    }
}

private struct LibraryKeyShortcuts: ViewModifier {
    let model: AppModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
                    nonisolated(unsafe) let event = event   // local monitors run on the main thread
                    let handled = MainActor.assumeIsolated { Self.handle(event, model: model) }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard let window = event.window, !window.isSheet, !(window is NSPanel),
              !((window.firstResponder as? NSTextView)?.isEditable ?? false),
              !event.isARepeat else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.charactersIgnoringModifiers?.lowercased(), mods) {
        case ("a", .command) where model.mode == .library:
            model.selectAll()
            return true
        case ("d", []):
            model.mode = .develop
            return true
        default:
            return false
        }
    }
}
