//
//  BulkEditor.swift
//  sloproom
//
//  Runs bulk edits (Paste / Sync Settings, Bulk Crop, Reset Edits) and makes each ONE undo step.
//
//  - Only the photo open in Develop as target: the edit goes through the Develop session (one
//    session undo step, exactly like the inspector's own actions).
//  - Otherwise: pending Develop edits are flushed, `BulkEdit.apply` runs off the main thread
//    (chunked transactions; a progress HUD for more than 20 photos), the open Develop session
//    shows its photo's new settings (`adoptExternalSettings`, no extra undo step / save), and ONE
//    step is registered with the main window's UndoManager. Previews regenerate through the usual
//    edit_version invalidation (nothing is rendered here).
//
//  Undo / Redo routing (Edit menu, ⌘Z / ⇧⌘Z: `EditUndoRouter`):
//  - Library: a bulk step on top of the window's UndoManager is undone directly; anything else
//    goes to the responder chain as before (text fields keep their own undo).
//  - Develop: the session's own steps and bulk steps are undone newest first. A bulk step made in
//    this session at session depth d is newer than the session's steps up to d; a bulk step made
//    before this session opened is older than all of its steps. Redo replays in reverse order.
//

import AppKit
import Foundation
import Observation

// MARK: - Progress

/// The bulk operation in progress (HUD at the bottom of the main window for > 20 photos).
@Observable
final class BulkProgress {
    static let shared = BulkProgress()
    static let threshold = 20

    private(set) var title = ""
    private(set) var done = 0
    private(set) var total = 0
    private(set) var isActive = false
    /// Operations still running (DevScript `act wait`).
    private(set) var running = 0

    func begin(_ title: String, total: Int) {
        running += 1
        guard total > Self.threshold else { return }
        self.title = title
        self.total = total
        done = 0
        isActive = true
    }

    func update(_ done: Int) { if isActive { self.done = done } }

    func end() {
        running = max(0, running - 1)
        if running == 0 { isActive = false }
    }
}

// MARK: - Bulk editor

enum BulkEditor {
    /// Applies `transform` to `ids` (list order) as one undoable step named `title`.
    static func apply(_ title: String, ids: [Int64], model: AppModel,
                      transform: @escaping @Sendable (Photo, EditSettings) -> EditSettings?) {
        guard !ids.isEmpty else { return }
        let session = model.developSession

        // Just the photo being edited: the session's own undo, like its inspector actions.
        if model.mode == .develop, let session, ids == [session.photo.id] {
            var photo = session.photo
            let size = session.orientedSize   // decoded size once loaded (exact), else metadata
            if photo.orientedSize != size { (photo.width, photo.height, photo.orientation) = (Int(size.width), Int(size.height), 1) }
            guard let new = transform(photo, session.settings), new != session.settings else { return }
            session.commitUndoGroup()
            session.settings = new
            session.commitUndoGroup()
            return
        }

        // The open photo's newest settings win over the catalog's (its save is debounced).
        var current: [Int64: EditSettings] = [:]
        if let session, ids.contains(session.photo.id) {
            session.commitUndoGroup()
            session.saveNow()
            DevelopSession.flushPendingSaves()
            current[session.photo.id] = session.settings
        }
        let catalog = model.catalog
        let progress = BulkProgress.shared
        progress.begin(title, total: ids.count)
        let t0 = Date()
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try BulkEdit.apply(catalog: catalog, ids: ids, current: current, transform: transform) { done, _ in
                    Task { @MainActor in progress.update(done) }
                }
            }
            await MainActor.run {
                progress.end()
                switch result {
                case .success(let change):
                    BulkEditUndo.shared.adopt(change.after, model: model)
                    BulkEditUndo.shared.register(title, change: change, model: model)
                    #if DEBUG
                    print("BulkEdit: \(title) \(change.ids.count) photo(s), skipped \(change.skipped.count), "
                          + "\(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    #endif
                case .failure(let error):
                    model.report(error)
                }
            }
        }
    }
}

// MARK: - Undo

final class BulkEditUndo {
    static let shared = BulkEditUndo()

    struct Step {
        let id = UUID()
        let title: String
        let change: BulkEditChange
        /// The Develop session open when the step was made (its undo depth then).
        weak var session: DevelopSession?
        let sessionDepth: Int
    }

    private enum Kind { case bulk, session }

    /// Mirrors the bulk entries of the window's UndoManager (top = last).
    private(set) var undoSteps: [Step] = []
    private(set) var redoSteps: [Step] = []
    /// Develop: what each Undo undid, so Redo replays in reverse order.
    private var developUndone: [Kind] = []
    private weak var model: AppModel?

    var undoManager: UndoManager? { ShortcutDispatcher.shared.mainWindow?.undoManager }

    /// A bulk step is the next thing the window's UndoManager would undo.
    var bulkUndoOnTop: Bool {
        guard let um = undoManager, um.canUndo, let top = undoSteps.last else { return false }
        return um.undoActionName == top.title
    }

    var bulkRedoOnTop: Bool {
        guard let um = undoManager, um.canRedo, let top = redoSteps.last else { return false }
        return um.redoActionName == top.title
    }

    func register(_ title: String, change: BulkEditChange, model: AppModel) {
        guard !change.isEmpty, let um = undoManager else { return }
        self.model = model
        let session = model.developSession
        let step = Step(title: title, change: change, session: session, sessionDepth: session?.undoDepth ?? 0)
        undoSteps.append(step)
        redoSteps.removeAll()
        developUndone.removeAll()
        um.registerUndo(withTarget: self) { $0.undo(step) }
        um.setActionName(title)
    }

    /// UndoManager callback: restores `before` and registers the redo.
    private func undo(_ step: Step) {
        undoSteps.removeAll { $0.id == step.id }
        redoSteps.append(step)
        undoManager?.registerUndo(withTarget: self) { $0.redo(step) }
        undoManager?.setActionName(step.title)
        write(step.change.before, order: step.change.ids, title: "Undo \(step.title)")
    }

    private func redo(_ step: Step) {
        redoSteps.removeAll { $0.id == step.id }
        undoSteps.append(step)
        undoManager?.registerUndo(withTarget: self) { $0.undo(step) }
        undoManager?.setActionName(step.title)
        write(step.change.after, order: step.change.ids, title: "Redo \(step.title)")
    }

    private func write(_ values: [Int64: EditSettings?], order: [Int64], title: String) {
        guard let model else { return }
        adopt(values, model: model)
        let catalog = model.catalog
        let progress = BulkProgress.shared
        progress.begin(title, total: order.count)
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try BulkEdit.write(values, order: order, catalog: catalog) { done, _ in
                    Task { @MainActor in progress.update(done) }
                }
            }
            await MainActor.run {
                progress.end()
                if case .failure(let error) = result { model.report(error) }
            }
        }
    }

    /// The Develop session shows its photo's new settings at once (no undo step, no save).
    func adopt(_ values: [Int64: EditSettings?], model: AppModel) {
        guard let session = model.developSession, let value = values[session.photo.id] else { return }
        session.adoptExternalSettings(value ?? EditSettings())
    }

    // MARK: Routing (Edit > Undo / Redo)

    /// Whether the top bulk step is newer than the session's newest own step.
    private func bulkIsNewer(than session: DevelopSession) -> Bool {
        guard let top = undoSteps.last else { return false }
        if top.session === session { return session.undoDepth <= top.sessionDepth }
        return session.undoDepth == 0
    }

    func undo(model: AppModel) {
        self.model = model
        if model.mode == .develop, let session = model.developSession {
            if bulkUndoOnTop, bulkIsNewer(than: session) {
                undoManager?.undo(); developUndone.append(.bulk)
            } else if session.canUndo {
                session.undo(); developUndone.append(.session)
            } else if bulkUndoOnTop {
                undoManager?.undo(); developUndone.append(.bulk)
            }
            return
        }
        if bulkUndoOnTop, !TextInputGuard.isEditingText { undoManager?.undo(); return }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    func redo(model: AppModel) {
        self.model = model
        if model.mode == .develop, let session = model.developSession {
            let last = developUndone.popLast()
            if last == .bulk, bulkRedoOnTop { undoManager?.redo(); return }
            if last == .session, session.canRedo { session.redo(); return }
            if session.canRedo { session.redo() } else if bulkRedoOnTop { undoManager?.redo() }
            return
        }
        if bulkRedoOnTop, !TextInputGuard.isEditingText { undoManager?.redo(); return }
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }

    #if DEBUG
    var debugDescription: String {
        let um = undoManager
        return "undo=\(undoSteps.map { "\($0.title)×\($0.change.ids.count)" }) redo=\(redoSteps.map(\.title)) "
            + "um.canUndo=\(um?.canUndo ?? false) '\(um?.undoActionName ?? "")' um.canRedo=\(um?.canRedo ?? false) "
            + "bulkOnTop=\(bulkUndoOnTop) redoOnTop=\(bulkRedoOnTop) developUndone=\(developUndone)"
    }
    #endif
}
