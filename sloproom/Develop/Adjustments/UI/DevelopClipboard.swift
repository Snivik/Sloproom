//
//  DevelopClipboard.swift
//  sloproom
//
//  Copy Settings / Paste Settings (⇧⌘C / ⇧⌘V) between photos. Copies the global adjustments
//  (white balance, tone, presence, color mixer, effects); crop/geometry and masks are excluded
//  and the target keeps its own. In Library mode, paste applies to every selected photo.
//

import Foundation

enum DevelopClipboard {
    /// The last copied settings (in-app only; not the system pasteboard).
    static var copied: EditSettings?

    /// `source`'s global adjustments on top of `target`'s geometry and masks.
    static func merge(_ source: EditSettings, into target: EditSettings) -> EditSettings {
        var out = target
        out.whiteBalance = source.whiteBalance
        out.tone = source.tone
        out.presence = source.presence
        out.colorMixer = source.colorMixer
        out.effects = source.effects
        return out
    }
}

extension DevelopSession {
    func copySettings() { DevelopClipboard.copied = settings }

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

    /// Develop: the open photo. Library: the focused photo.
    func copyDevelopSettings() {
        if mode == .develop, let session = developSession { session.copySettings(); return }
        if let photo = focusedPhoto { DevelopClipboard.copied = photo.editSettings }
    }

    /// Develop: the open photo (undoable). Library: every selected photo (written to the catalog).
    func pasteDevelopSettings() {
        guard let copied = DevelopClipboard.copied else { return }
        if mode == .develop, let session = developSession { session.pasteSettings(); return }
        let targets = actionTargetIDs.compactMap { photo(id: $0) }
        guard !targets.isEmpty else { return }
        let catalog = catalog
        let edits = targets.map { ($0.id, DevelopClipboard.merge(copied, into: $0.editSettings)) }
        Task.detached(priority: .userInitiated) {
            do {
                for (id, settings) in edits { _ = try catalog.saveEditSettings(settings, for: id) }
            } catch {
                await MainActor.run { self.report(error) }
            }
        }
    }
}
