//
//  DevelopClipboard.swift
//  sloproom
//
//  Copy Settings / Paste Settings (⇧⌘C / ⇧⌘V) between photos — registry actions of the photo
//  actions primitive (Actions/PhotoActions.swift): Copy (one photo) copies ALL its settings;
//  Paste (one or more photos) applies the sections chosen in "Choose Settings to Paste…"
//  (`pasteSections`, remembered; default: white balance, tone, presence, color mixer, effects —
//  crop/geometry and masks excluded, the target keeps its own). Pasting onto several photos is
//  a bulk edit (one undo step); onto the photo open in Develop, one Develop undo step.
//

import Foundation

enum DevelopClipboard {
    /// The last copied settings (in-app only; not the system pasteboard).
    static var copied: EditSettings?
    /// Title of the photo they were copied from (shown by "Choose Settings to Paste…").
    static var copiedFrom: String?

    static let pasteSectionsKey = "actions.pasteSections"

    /// Sections Paste Settings applies (Choose Settings to Paste… changes them).
    static var pasteSections: Set<EditSection> {
        get { EditSection.decode(UserDefaults.standard.string(forKey: pasteSectionsKey)) ?? EditSection.pasteDefault }
        set { UserDefaults.standard.set(EditSection.encode(newValue), forKey: pasteSectionsKey) }
    }

    static func copy(_ settings: EditSettings, from photo: Photo) {
        copied = settings
        copiedFrom = photo.displayTitle
    }

    /// `source`'s chosen sections on top of `target` (default: global adjustments; the target
    /// keeps its geometry and masks).
    static func merge(_ source: EditSettings, into target: EditSettings) -> EditSettings {
        target.replacing(pasteSections, from: source)
    }
}

extension DevelopSession {
    func copySettings() { DevelopClipboard.copy(settings, from: photo) }

    /// Undoable.
    func pasteSettings() {
        guard let copied = DevelopClipboard.copied else { return }
        commitUndoGroup()
        settings = DevelopClipboard.merge(copied, into: settings)
        commitUndoGroup()
    }
}

extension AppModel {
    var canPasteDevelopSettings: Bool { DevelopClipboard.copied != nil }

    /// Photo > Copy Settings (registry action: one target).
    func copyDevelopSettings() { PhotoActions.performFromMenu(.copySettings, model: self) }

    /// Photo > Paste Settings (registry action: the action targets; one undo step).
    func pasteDevelopSettings() { PhotoActions.performFromMenu(.pasteSettings, model: self) }
}
