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
//    ⌘= / ⌘+      zoom in to the next preset   ⌘- / ⌘_   zoom out to the previous preset
//    ⌘0           zoom to Fit
//    Space (held) temporary hand tool (drag pans, even over crop / mask tools)
//    pinch        free-form zoom around the fingers (Fit … 800 %; the sharp render follows a
//                 150 ms pause / the end of the gesture)      ⌘/⌥ + scroll  zoom around the cursor
//    two-finger double tap (smart magnify)   Fit ↔ 100 % at the pointer
//    two-finger scroll / wheel            pan (when zoomed)
//
//  The handlers (`handleMagnify`, `handleSmartMagnify`) are also what DevScript `pinch` /
//  `smartmagnify` reach: those post real NSEvents (.magnify / .smartMagnify) through the app's
//  event queue, so the same monitor sees them.
//
//  `isActive` gates everything (e.g. Develop mode only; the Library uses ⌘= / ⌘- for
//  thumbnail size — a different scope, see ShortcutModel).
//

import AppKit
import QuartzCore
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
            ShortcutHandler(.zoomFit, when: mine) { [weak zoom] _ in
                guard let zoom, !zoom.isLocked else { return }
                zoom.zoomToFit()
            },
            ShortcutHandler(.temporaryHand, when: mine, release: { [weak zoom] in zoom?.spaceHeld = false }) { [weak zoom] _ in
                zoom?.spaceHeld = true
            },
        ]
    }

    private func install() {
        guard monitor == nil else { return }
        let zoom = zoom, isActive = isActive
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { event in
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
        guard [.scrollWheel, .magnify, .smartMagnify].contains(event.type), let w = zoom.window,
              w.frame.contains(event.locationInWindow) else { return nil }
        return (w, w.convertPoint(fromScreen: event.locationInWindow))
    }

    private static func handle(_ event: NSEvent, zoom: ZoomController, isActive: () -> Bool) -> Bool {
        guard let (window, location) = target(event, zoom: zoom), window === zoom.window, isActive() else { return false }
        switch event.type {
        case .scrollWheel:
            return handleScroll(event, location: location, zoom: zoom, window: window)
        case .magnify:
            return handleMagnify(event, location: location, zoom: zoom, window: window)
        case .smartMagnify:
            guard let p = zoom.canvasPoint(fromWindow: location, in: window),
                  CGRect(origin: .zero, size: zoom.canvasFrame.size).contains(p), !zoom.isLocked else { return false }
            zoom.smartMagnify(at: p)
            return true
        default:
            return false
        }
    }

    /// Pinch: free-form zoom anchored at the fingers. A pinch that started over the canvas keeps
    /// zooming (anchor clamped onto the image) even if the pointer drifts off it, and its end is
    /// always delivered so the sharp render starts.
    private static func handleMagnify(_ event: NSEvent, location: NSPoint, zoom: ZoomController, window: NSWindow) -> Bool {
        let start = CACurrentMediaTime()
        guard let p = zoom.canvasPoint(fromWindow: location, in: window) else { return false }
        let inside = CGRect(origin: .zero, size: zoom.canvasFrame.size).contains(p)
        let phase: ZoomController.GesturePhase
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { phase = .began }
        else if event.phase.contains(.ended) || event.phase.contains(.cancelled) { phase = .ended }
        else if event.phase.isEmpty { phase = .none }
        else { phase = .changed }
        guard !zoom.isLocked, inside || (zoom.gestureActive && phase != .began) else { return false }
        if phase == .began { zoom.stats = ZoomController.GestureStats() }
        zoom.magnify(by: 1 + event.magnification, anchor: p, phase: phase)
        let ms = (CACurrentMediaTime() - start) * 1000
        zoom.stats.events += 1
        zoom.stats.handlerMSTotal += ms
        zoom.stats.handlerMSMax = max(zoom.stats.handlerMSMax, ms)
        FrameCostProbe.shared.eventHandled(at: start, zoom: zoom)
        return true
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

/// Measures what a pinch event costs on screen: from the first (unrendered) magnify event to the
/// end of the main run loop iteration that committed it (SwiftUI's update + Core Animation commit
/// run in `beforeWaiting` observers; this one runs after them).
@MainActor
final class FrameCostProbe {
    static let shared = FrameCostProbe()
    private var pendingSince: CFTimeInterval?
    private weak var zoom: ZoomController?
    private var observer: CFRunLoopObserver?

    func eventHandled(at start: CFTimeInterval, zoom: ZoomController) {
        if pendingSince == nil { pendingSince = start }
        self.zoom = zoom
        guard observer == nil else { return }
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { _, _ in
            MainActor.assumeIsolated { FrameCostProbe.shared.committed() }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    private func committed() {
        guard let since = pendingSince, let zoom else { return }
        pendingSince = nil
        let ms = (CACurrentMediaTime() - since) * 1000
        zoom.stats.frames += 1
        zoom.stats.frameMSTotal += ms
        zoom.stats.frameMSMax = max(zoom.stats.frameMSMax, ms)
    }
}
