//
//  CropKeyMonitor.swift
//  sloproom
//
//  Crop keyboard shortcuts while Develop is showing (installed by CropPanel), registered with
//  the shortcut dispatcher (keys = the user's bindings; defaults below):
//    R        toggle the crop tool          ⌘[ / ⌘]  rotate left / right      (scope Develop)
//  and while the crop tool is active (scope Crop Tool):
//    X        swap portrait / landscape     O        cycle grid overlay
//    Return   commit                        Esc      cancel (restore geometry)
//
//  The dispatcher sees key events before menu key equivalents and the crop scope is narrower
//  than "everywhere", so X swaps the crop instead of rejecting the photo (Photo > Reject) while
//  cropping. Auto-repeats are swallowed (holding X never falls through to Reject). Keys are
//  ignored while a text field is being edited or a sheet is up.
//

import AppKit
import SwiftUI

extension View {
    /// Installs the crop keyboard shortcuts for `session` while this view is on screen.
    func cropKeyboardShortcuts(session: DevelopSession) -> some View {
        shortcutHandlers(id: ObjectIdentifier(session)) { [weak session] in
            guard let session else { return [] }
            let cropping: @MainActor (NSEvent) -> Bool = { [weak session] _ in session?.isCropping ?? false }
            return [
                ShortcutHandler(.toggleCropTool) { [weak session] _ in session?.toggleCropTool() },
                ShortcutHandler(.rotateLeft) { [weak session] _ in session?.rotateQuarter(clockwise: false) },
                ShortcutHandler(.rotateRight) { [weak session] _ in session?.rotateQuarter(clockwise: true) },
                ShortcutHandler(.cropCommit, when: cropping) { [weak session] _ in session?.commitCrop() },
                ShortcutHandler(.cropCancel, when: cropping) { [weak session] _ in session?.cancelCrop() },
                ShortcutHandler(.cropSwapAspect, when: cropping) { [weak session] _ in session?.swapCropOrientation() },
                ShortcutHandler(.cropGridOverlay, when: cropping) { [weak session] _ in
                    guard let session else { return }
                    session.cropTool.gridMode = session.cropTool.gridMode.next
                },
            ]
        }
    }
}
