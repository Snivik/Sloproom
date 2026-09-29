//
//  ZoomEventMonitor.swift
//  sloproom
//
//  Keyboard / trackpad input of a zoomable canvas. Keys are registry actions (scope "Develop &
//  Full Screen", handlers registered with the shortcut dispatcher, keys = the user's bindings;
//  defaults below); trackpad / wheel input is a local event monitor. Only events of the
//  canvas' own window are handled; keys yield while a text field is edited or a sheet is up.
//
//    Z            toggle Fit ↔ zoom (1:1 by default) at the mouse position
//    ⌘= / ⌘+      zoom in one step        ⌘-   zoom out one step
//    Space (held) temporary hand tool (drag pans, even over crop / mask tools)
//    pinch        zoom around the cursor  ⌘/⌥ + scroll  zoom around the cursor
//    two-finger scroll / wheel            pan (when zoomed)
//
//  `isActive` gates everything (e.g. Develop mode only; the Library uses ⌘= / ⌘- for
//  thumbnail size — a different scope, see ShortcutModel).
//

import AppKit
import SwiftUI

extension View {
    /// Installs zoom / pan input for `zoom` while this view is on screen.
    func zoomEventMonitor(_ zoom: ZoomController, isActive: @escaping @MainActor () -> Bool) -> some View {
        modifier(ZoomEventMonitor(zoom: zoom, isActive: isActive))
    }
}

private struct ZoomEventMonitor: ViewModifier {
    let zoom: ZoomController
    let isActive: @MainActor () -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .shortcutHandlers { [zoom, isActive] in Self.keyHandlers(zoom: zoom, isActive: isActive) }
            // A space released while another app is frontmost never reaches us.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                zoom.spaceHeld = false
                ShortcutDispatcher.shared.releaseHeldKeys()
            }
    }

    /// Z / ⌘= / ⌘- / Space. Consumed even while zoom is locked (crop tool), as before.
    private static func keyHandlers(zoom: ZoomController, isActive: @escaping @MainActor () -> Bool) -> [ShortcutHandler] {
        let mine: @MainActor (NSEvent) -> Bool = { [weak zoom] event in
            event.window != nil && event.window === zoom?.window && isActive()
        }
        return [
            ShortcutHandler(.zoomToggle, when: mine) { [weak zoom] _ in
                guard let zoom, !zoom.isLocked else { return }
                zoom.toggle(at: zoom.mouseLocation)
            },
            ShortcutHandler(.zoomIn, when: mine) { [weak zoom] _ in
                guard let zoom, !zoom.isLocked else { return }
                zoom.step(zoomIn: true, anchor: zoom.mouseLocation)
            },
            ShortcutHandler(.zoomOut, when: mine) { [weak zoom] _ in
                guard let zoom, !zoom.isLocked else { return }
                zoom.step(zoomIn: false, anchor: zoom.mouseLocation)
            },
            ShortcutHandler(.temporaryHand, when: mine, release: { [weak zoom] in zoom?.spaceHeld = false }) { [weak zoom] _ in
                zoom?.spaceHeld = true
            },
        ]
    }

    private func install() {
        guard monitor == nil else { return }
        let zoom = zoom, isActive = isActive
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            let handled = MainActor.assumeIsolated { Self.handle(event, zoom: zoom, isActive: isActive) }
            return handled ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        zoom.spaceHeld = false
    }

    /// The event's window and its location in it. Window-less pointer events (e.g. posted
    /// scroll events) carry screen coordinates; they count when over the canvas' window.
    private static func target(_ event: NSEvent, zoom: ZoomController) -> (NSWindow, NSPoint)? {
        if let w = event.window { return (w, event.locationInWindow) }
        guard event.type == .scrollWheel || event.type == .magnify, let w = zoom.window,
              w.frame.contains(event.locationInWindow) else { return nil }
        return (w, w.convertPoint(fromScreen: event.locationInWindow))
    }

    private static func handle(_ event: NSEvent, zoom: ZoomController, isActive: () -> Bool) -> Bool {
        guard let (window, location) = target(event, zoom: zoom), window === zoom.window, isActive() else { return false }
        switch event.type {
        case .scrollWheel:
            return handleScroll(event, location: location, zoom: zoom, window: window)
        case .magnify:
            guard let p = zoom.canvasPoint(fromWindow: location, in: window),
                  CGRect(origin: .zero, size: zoom.canvasFrame.size).contains(p),
                  !zoom.isLocked else { return false }
            zoom.magnify(by: 1 + event.magnification, anchor: p)
            return true
        default:
            return false
        }
    }

    private static func handleScroll(_ event: NSEvent, location: NSPoint, zoom: ZoomController, window: NSWindow) -> Bool {
        guard let p = zoom.canvasPoint(fromWindow: location, in: window),
              CGRect(origin: .zero, size: zoom.canvasFrame.size).contains(p) else { return false }
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX * (precise ? 1 : 12), dy = event.scrollingDeltaY * (precise ? 1 : 12)
        let mods = event.modifierFlags.intersection([.command, .option])
        if !mods.isEmpty {
            guard !zoom.isLocked, dy != 0 else { return !zoom.isLocked }
            zoom.magnify(by: exp(dy * (precise ? 0.006 : 0.004)), anchor: p)
            return true
        }
        guard zoom.isZoomed else { return false }
        zoom.pan(by: CGSize(width: dx, height: dy))
        return true
    }
}
