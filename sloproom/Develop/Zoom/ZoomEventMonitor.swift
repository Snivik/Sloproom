//
//  ZoomEventMonitor.swift
//  sloproom
//
//  Keyboard / trackpad input of a zoomable canvas, as local event monitors (they see events
//  before menu key equivalents and regardless of which view has focus). Only events of the
//  canvas' own window are handled; keys yield while a text field is edited or a sheet is up.
//
//    Z            toggle Fit ↔ zoom (1:1 by default) at the mouse position
//    ⌘= / ⌘+      zoom in one step        ⌘-   zoom out one step
//    Space (held) temporary hand tool (drag pans, even over crop / mask tools)
//    pinch        zoom around the cursor  ⌘/⌥ + scroll  zoom around the cursor
//    two-finger scroll / wheel            pan (when zoomed)
//
//  `isActive` gates everything (e.g. Develop mode only; the Library uses ⌘= / ⌘- itself).
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
            // A space released while another app is frontmost never reaches us.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                zoom.spaceHeld = false
            }
    }

    private func install() {
        guard monitor == nil else { return }
        let zoom = zoom, isActive = isActive
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .magnify]) { event in
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
        guard let (window, location) = target(event, zoom: zoom), window === zoom.window, isActive() else {
            if event.type == .keyUp, event.keyCode == 49 { zoom.spaceHeld = false }
            return false
        }
        switch event.type {
        case .keyDown, .keyUp:
            guard window.attachedSheet == nil, !TextInputGuard.isEditingText else { return false }
            return handleKey(event, zoom: zoom)
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

    private static func handleKey(_ event: NSEvent, zoom: ZoomController) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49, mods.isEmpty || event.type == .keyUp {   // space
            zoom.spaceHeld = event.type == .keyDown
            return true
        }
        guard event.type == .keyDown else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if mods.isEmpty, key.lowercased() == "z" {
            if !event.isARepeat, !zoom.isLocked { zoom.toggle(at: zoom.mouseLocation) }
            return true
        }
        if mods == .command || mods == [.command, .shift] {
            switch key {
            case "=", "+":
                if !zoom.isLocked { zoom.step(zoomIn: true, anchor: zoom.mouseLocation) }
                return true
            case "-", "_":
                if !zoom.isLocked { zoom.step(zoomIn: false, anchor: zoom.mouseLocation) }
                return true
            default: return false
            }
        }
        return false
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
