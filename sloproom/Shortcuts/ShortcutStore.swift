//
//  ShortcutStore.swift
//  sloproom
//
//  The user's key bindings: defaults (`ShortcutAction.defaultBinding`) plus overrides persisted
//  in UserDefaults (`shortcuts.overrides` = [action id: spec], "" = no shortcut). UI-free
//  (Foundation + Observation), so Tools/shortcuts_check.swift can test it.
//
//    ShortcutStore.shared.binding(for: .pick)          // KeyCombo? (nil = none)
//    store.setBinding(KeyCombo("k"), for: .pick)       // persists; equal to default = no override
//    store.reset(.pick); store.resetAll()
//    store.conflicts(for: combo, action: .pick)        // actions in same / overlapping scopes
//    store.candidates(for: pressed, in: .crop)         // actions a key press may trigger there, narrowest scope first
//    store.help("Pick", .pick)                         // "Pick (P)" for tooltips
//
//  AppKit / SwiftUI glue (NSEvent → KeyCombo, menu items, the key dispatcher): ShortcutKeys.swift.
//

import Foundation
import Observation

@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let defaultsKey = "shortcuts.overrides"
    /// Incremented on every change (menu bar Commands observe it with @AppStorage).
    static let revisionKey = "shortcuts.revision"
    /// Posted (object = the store) after every change.
    static let didChangeNotification = Notification.Name("ShortcutStore.didChange")

    /// Action id → spec ("" = explicitly no shortcut). Only actions that differ from the default.
    private(set) var overrides: [String: String] = [:]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    // MARK: Bindings

    func binding(for action: ShortcutAction) -> KeyCombo? {
        if let spec = overrides[action.id] { return KeyCombo(spec: spec) }
        return action.defaultBinding
    }

    func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action.id] != nil }

    /// Sets (nil = removes) the shortcut of `action`. Doesn't touch other actions (see `reassign`).
    func setBinding(_ combo: KeyCombo?, for action: ShortcutAction) {
        if combo == action.defaultBinding {
            overrides[action.id] = nil
        } else {
            overrides[action.id] = combo?.spec ?? ""
        }
        save()
    }

    /// Gives `combo` to `action` and removes it from every conflicting action.
    func reassign(_ combo: KeyCombo, to action: ShortcutAction) {
        for other in conflicts(for: combo, action: action) { setBinding(nil, for: other) }
        setBinding(combo, for: action)
    }

    func reset(_ action: ShortcutAction) {
        overrides[action.id] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    private func save() {
        if overrides.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(overrides, forKey: Self.defaultsKey) }
        defaults.set(defaults.integer(forKey: Self.revisionKey) &+ 1, forKey: Self.revisionKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Conflicts

    /// Actions that `combo` would be ambiguous with if bound to `action`: same key, scopes that
    /// overlap without one overriding the other, and not focus-exclusive (grid vs sidebar).
    func conflicts(for combo: KeyCombo, action: ShortcutAction) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { other in
            guard other != action, let b = binding(for: other), b.overlaps(combo) else { return false }
            return Self.scopesConflict(action, other)
        }
    }

    /// Current conflicts of `action`'s own binding.
    func conflicts(of action: ShortcutAction) -> [ShortcutAction] {
        guard let combo = binding(for: action) else { return [] }
        return conflicts(for: combo, action: action)
    }

    /// Broader-scope actions with the same key that `action` overrides in its scope
    /// (e.g. Swap Portrait / Landscape overrides Reject in the crop tool).
    func overridden(by action: ShortcutAction) -> [ShortcutAction] {
        guard let combo = binding(for: action) else { return [] }
        return ShortcutAction.allCases.filter { other in
            other != action && (binding(for: other)?.overlaps(combo) ?? false) && action.scope.isNarrower(than: other.scope)
        }
    }

    static func scopesConflict(_ a: ShortcutAction, _ b: ShortcutAction) -> Bool {
        if let ga = a.focusGroup, let gb = b.focusGroup, ga != gb { return false }
        return a.scope.conflicts(with: b.scope)
    }

    /// Every pair of conflicting actions (for diagnostics).
    var allConflicts: [(ShortcutAction, ShortcutAction)] {
        let all = ShortcutAction.allCases
        var result: [(ShortcutAction, ShortcutAction)] = []
        for (i, a) in all.enumerated() {
            guard let ca = binding(for: a) else { continue }
            for b in all[(i + 1)...] where Self.scopesConflict(a, b) {
                if let cb = binding(for: b), ca.overlaps(cb) { result.append((a, b)) }
            }
        }
        return result
    }

    // MARK: Resolution

    /// Actions a key press triggers in `context`, the narrowest scope first (a narrower scope
    /// overrides a broader one; the dispatcher performs the first one whose handler is available).
    func candidates(for pressed: KeyCombo, in context: ShortcutContext) -> [ShortcutAction] {
        ShortcutAction.allCases.enumerated()
            .filter { _, action in
                guard action.scope.contexts.contains(context), let b = binding(for: action) else { return false }
                return b.accepts(pressed, extraShift: action.acceptsExtraShift)
            }
            .sorted { a, b in   // narrowest scope first, enum order within the same scope size
                let (na, nb) = (a.element.scope.contexts.count, b.element.scope.contexts.count)
                return na != nb ? na < nb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Whether `pressed` is `action`'s binding (ignores scopes; for key-up of held keys).
    func matches(_ pressed: KeyCombo, _ action: ShortcutAction) -> Bool {
        binding(for: action)?.accepts(pressed, extraShift: action.acceptsExtraShift) ?? false
    }

    // MARK: Display

    /// "⇧⌘E", or "" when the action has no shortcut.
    func display(_ action: ShortcutAction) -> String { binding(for: action)?.display ?? "" }

    /// Tooltip text with the current shortcut: "Pick (P)", "Rotate Left (⌘[)"; just `text` if unbound.
    func help(_ text: String, _ action: ShortcutAction?) -> String {
        guard let action, let combo = binding(for: action) else { return text }
        return "\(text) (\(combo.display))"
    }

    /// " (⎋ cancels)" — a key hint to append to a longer tooltip; "" if unbound.
    func hint(_ verb: String, _ action: ShortcutAction) -> String {
        guard let combo = binding(for: action) else { return "" }
        return " (\(combo.display) \(verb))"
    }

    /// "Zoom In / Zoom Out (⌘= / ⌘-)" style: several actions' keys in one tooltip.
    func help(_ text: String, _ actions: [ShortcutAction]) -> String {
        let keys = actions.compactMap { binding(for: $0)?.display }
        return keys.isEmpty ? text : "\(text) (\(keys.joined(separator: " / ")))"
    }
}
