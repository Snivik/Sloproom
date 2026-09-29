//
//  DevelopPanels.swift
//  sloproom
//
//  Panel visibility in Develop (remembered for the app session, not across launches):
//    Tab     hide / show the side panels (folder sidebar + inspector)
//    ⇧Tab    "lights out": hide / show sidebar, inspector AND filmstrip (canvas only)
//  (defaults; the keys come from the shortcut registry)
//  The Library keeps its own sidebar visibility (`columnVisibility(mode:)` is the
//  NavigationSplitView binding MainWindowView uses).
//

import AppKit
import SwiftUI

@Observable
final class DevelopPanels {
    static let shared = DevelopPanels()

    var sidebarHidden = false
    var inspectorHidden = false
    var filmstripHidden = false
    /// Sidebar visibility of the Library (the user's own toggle there).
    var libraryColumns: NavigationSplitViewVisibility = .all

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

    /// NavigationSplitView column visibility for the current mode.
    func columnVisibility(mode: AppMode) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { [self] in mode == .develop ? (sidebarHidden ? .detailOnly : .all) : libraryColumns },
            set: { [self] v in
                if mode == .develop { sidebarHidden = v == .detailOnly } else { libraryColumns = v }
            }
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
