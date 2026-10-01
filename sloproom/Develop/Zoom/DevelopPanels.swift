//
//  DevelopPanels.swift
//  sloproom
//
//  Panel visibility (remembered for the app session, not across launches):
//    Tab     hide / show the side panels in Develop (folder sidebar + inspector)
//    ⇧Tab    "lights out" in Develop: hide / show sidebar, inspector AND filmstrip (canvas only)
//    ⌃⌘S     View > Show / Hide Folders (also the toolbar's sidebar button), Library and Develop
//  (defaults; the keys come from the shortcut registry)
//
//  The folder sidebar's visibility is remembered PER MODE (`librarySidebarHidden` /
//  `sidebarHidden`); `columnVisibility(model:)` is MainWindowView's NavigationSplitView binding.
//  It reads the mode when it is called, never when it is created: SwiftUI keeps using the
//  binding the split view's toolbar toggle was set up with, so a binding that captured the mode
//  wrote Develop's toggles into the Library state (the "sidebar button does nothing in Develop" bug).
//

import AppKit
import SwiftUI

@Observable
final class DevelopPanels {
    static let shared = DevelopPanels()

    /// Develop: folder sidebar hidden.
    var sidebarHidden = false
    var inspectorHidden = false
    var filmstripHidden = false
    /// Library: folder sidebar hidden (the user's own toggle there).
    var librarySidebarHidden = false

    var allHidden: Bool { sidebarHidden && inspectorHidden && filmstripHidden }

    /// Tab: side panels.
    func toggleSidePanels() {
        let hide = !(sidebarHidden && inspectorHidden)
        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarHidden = hide
            inspectorHidden = hide
        }
    }

    /// ⇧Tab: everything but the canvas.
    func toggleLightsOut() {
        let hide = !allHidden
        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarHidden = hide
            inspectorHidden = hide
            filmstripHidden = hide
        }
    }

    func isSidebarHidden(in mode: AppMode) -> Bool {
        mode == .develop ? sidebarHidden : librarySidebarHidden
    }

    func setSidebarHidden(_ hidden: Bool, in mode: AppMode) {
        if mode == .develop {
            if sidebarHidden != hidden { sidebarHidden = hidden }
        } else if librarySidebarHidden != hidden {
            librarySidebarHidden = hidden
        }
    }

    /// View > Show / Hide Folders, the view bar's sidebar button.
    func toggleSidebar(in mode: AppMode) {
        let hide = !isSidebarHidden(in: mode)
        withAnimation(.easeInOut(duration: 0.2)) { setSidebarHidden(hide, in: mode) }
    }

    /// NavigationSplitView column visibility of the CURRENT mode (read at call time).
    func columnVisibility(model: AppModel) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { [self, weak model] in isSidebarHidden(in: model?.mode ?? .library) ? .detailOnly : .all },
            set: { [self, weak model] v in setSidebarHidden(v == .detailOnly, in: model?.mode ?? .library) }
        )
    }
}

extension View {
    /// Tab / ⇧Tab panel toggles while Develop is showing (installed by DevelopView; registry
    /// actions `toggleSidePanels` / `toggleAllPanels`, scope Develop).
    func developPanelShortcuts() -> some View {
        shortcutHandlers {
            [
                ShortcutHandler(.toggleSidePanels) { _ in DevelopPanels.shared.toggleSidePanels() },
                ShortcutHandler(.toggleAllPanels) { _ in DevelopPanels.shared.toggleLightsOut() },
            ]
        }
    }
}
