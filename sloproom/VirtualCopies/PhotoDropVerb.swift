//
//  PhotoDropVerb.swift
//  sloproom
//
//  What dropping photos on a sidebar folder does — Finder-like modifiers:
//  plain = Add (same photo, edits shared), ⌘ = Move (out of the shown folder; only while a
//  folder other than the target is shown), ⌥ = Copy (new virtual copies inside the target).
//  The drop proposal reflects it (Add = alias arrow, Move = plain arrow, Copy = green plus) and
//  the hovered folder row shows the verb (`PhotoDropVerbBadge`). Used by `FolderRowDropDelegate`.
//

import AppKit
import SwiftUI

enum PhotoDropVerb: String, CaseIterable {
    case add, move, copy

    /// The verb for the current modifier keys.
    static func current(onto folderID: Int64, model: AppModel) -> PhotoDropVerb {
        resolve(modifierOverride ?? NSEvent.modifierFlags, shownFolderID: model.shownFolderID, target: folderID)
    }

    /// DevScript drop tests (`vc droptest`) simulate modifier keys; nil = the real keyboard.
    static var modifierOverride: NSEvent.ModifierFlags?

    /// Pure decision (DevScript `vc dropverb`). ⌥ wins over ⌘.
    static func resolve(_ flags: NSEvent.ModifierFlags, shownFolderID: Int64?, target: Int64) -> PhotoDropVerb {
        if flags.contains(.option) { return .copy }
        if flags.contains(.command), let shown = shownFolderID, shown != target { return .move }
        return .add
    }

    var operation: DropOperation {
        switch self {
        case .add: if #available(macOS 26.0, *) { .alias } else { .copy }
        case .move: .move
        case .copy: .copy
        }
    }

    var title: String {
        switch self {
        case .add: "Add"
        case .move: "Move"
        case .copy: "Copy"
        }
    }

    var help: String {
        switch self {
        case .add: "Add: same photo, edits shared"
        case .move: "Move: take out of this folder"
        case .copy: "Copy: independent virtual copy with its own edits"
        }
    }

    var systemImage: String {
        switch self {
        case .add: "plus"
        case .move: "arrow.right"
        case .copy: "square.on.square"
        }
    }

    /// Performs the drop of `ids` on `folderID`.
    func perform(_ ids: [Int64], onto folderID: Int64, model: AppModel) {
        switch self {
        case .add: FolderActions.addPhotos(ids, to: folderID, move: false, model: model)
        case .move: FolderActions.addPhotos(ids, to: folderID, move: true, model: model)
        case .copy: VirtualCopyActions.copy(ids, to: folderID, model: model)
        }
    }
}

/// The folder row a photo drag hovers and what dropping would do (drives the row's badge).
@Observable
final class PhotoDropFeedback {
    static let shared = PhotoDropFeedback()
    var folderID: Int64?
    var verb: PhotoDropVerb = .add

    func update(_ folderID: Int64?, _ verb: PhotoDropVerb) {
        if self.folderID != folderID { self.folderID = folderID }
        if self.verb != verb { self.verb = verb }
    }
}

/// Small capsule at the trailing edge of a folder row while photos hover it: "Add" / "Move" / "Copy".
struct PhotoDropVerbBadge: View {
    let folderID: Int64
    private var feedback: PhotoDropFeedback { .shared }

    var body: some View {
        if feedback.folderID == folderID {
            Label(feedback.verb.title, systemImage: feedback.verb.systemImage)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .help(feedback.verb.help)
                .allowsHitTesting(false)
        }
    }
}
