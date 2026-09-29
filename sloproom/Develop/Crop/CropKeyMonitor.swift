//
//  CropKeyMonitor.swift
//  sloproom
//
//  Crop keyboard shortcuts while Develop is showing (installed by CropPanel):
//    R        toggle the crop tool          ⌘[ / ⌘]  rotate left / right
//  and while the crop tool is active:
//    X        swap portrait / landscape     O        cycle grid overlay
//    Return   commit                        Esc      cancel (restore geometry)
//
//  A local event monitor sees key events before menu key equivalents, so X swaps the crop
//  instead of rejecting the photo (Photo > Reject) while cropping. Keys are ignored while a
//  text field is being edited or a sheet is up.
//

import AppKit
import SwiftUI

private struct CropKeyMonitor: ViewModifier {
    let session: DevelopSession
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: ObjectIdentifier(session)) { _, _ in remove(); install() }
    }

    private func install() {
        guard monitor == nil else { return }
        let session = session
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.handle(event, session: session) } ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true if the event was consumed. Auto-repeats of a handled key are swallowed
    /// without acting (so holding X never falls through to Photo > Reject).
    private static func handle(_ event: NSEvent, session: DevelopSession) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.sheetParent == nil, window.attachedSheet == nil,
              !TextInputGuard.isEditingText, let action = action(for: event, session: session) else { return false }
        if !event.isARepeat { action() }
        return true
    }

    private static func action(for event: NSEvent, session: DevelopSession) -> (() -> Void)? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch key {
            case "[": return { session.rotateQuarter(clockwise: false) }
            case "]": return { session.rotateQuarter(clockwise: true) }
            default: return nil
            }
        }
        guard mods.isEmpty else { return nil }
        if key == "r" { return { session.toggleCropTool() } }
        guard session.isCropping else { return nil }
        switch event.keyCode {
        case 36, 76: return { session.commitCrop() }   // Return, keypad Enter
        case 53: return { session.cancelCrop() }       // Esc
        default: break
        }
        switch key {
        case "x": return { session.swapCropOrientation() }
        case "o": return { session.cropTool.gridMode = session.cropTool.gridMode.next }
        default: return nil
        }
    }
}

extension View {
    /// Installs the crop keyboard shortcuts for `session` while this view is on screen.
    func cropKeyboardShortcuts(session: DevelopSession) -> some View {
        modifier(CropKeyMonitor(session: session))
    }
}
