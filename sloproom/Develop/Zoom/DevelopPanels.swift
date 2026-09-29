//
//  DevelopPanels.swift
//  sloproom
//
//  Panel visibility in Develop (remembered for the app session, not across launches):
//    Tab     hide / show the side panels (folder sidebar + inspector)
//    ⇧Tab    "lights out": hide / show sidebar, inspector AND filmstrip (canvas only)
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
    /// Tab / ⇧Tab panel toggles while Develop is showing (installed by DevelopView).
    func developPanelShortcuts() -> some View {
        modifier(DevelopPanelKeyMonitor())
    }
}

private struct DevelopPanelKeyMonitor: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    nonisolated(unsafe) let event = event
                    let handled = MainActor.assumeIsolated { Self.handle(event) }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48, let window = event.window, !window.isSheet, !(window is NSPanel),
              window.attachedSheet == nil, !FullScreenPreview.shared.isShowing || window !== FullScreenPreview.shared.window,
              !TextInputGuard.isEditingText else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch mods {
        case []: if !event.isARepeat { DevelopPanels.shared.toggleSidePanels() }
        case .shift: if !event.isARepeat { DevelopPanels.shared.toggleLightsOut() }
        default: return false
        }
        return true
    }
}
