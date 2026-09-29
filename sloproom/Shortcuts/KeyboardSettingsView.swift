//
//  KeyboardSettingsView.swift
//  sloproom
//
//  Settings > Keyboard: every registry action grouped by category, searchable (name, key or
//  scope). Click a shortcut to record a new one: press the keys; Esc cancels, ⌫ removes the
//  shortcut. A key already used in the same / an overlapping scope asks before reassigning
//  ("Already used by Pick" → Reassign / Cancel). Per-row reset, Reset All.
//  Help > Keyboard Shortcuts… (and View > Keyboard Shortcuts…) open this tab.
//

import AppKit
import SwiftUI

enum SettingsTab: String, Hashable {
    case previews, drives, keyboard
}

/// Selected Settings tab (menu items open a specific tab).
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab: SettingsTab = .previews
    /// Search text of the Keyboard tab (kept while Settings is closed).
    var keyboardSearch = ""
}

/// "Keyboard Shortcuts…": opens Settings on the Keyboard tab.
struct KeyboardShortcutsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ShortcutMenuButton(.keyboardShortcuts) {
            SettingsNavigation.shared.tab = .keyboard
            openSettings()
        }
    }
}

struct KeyboardSettingsView: View {
    @Bindable private var navigation = SettingsNavigation.shared
    @State private var recorder = ShortcutRecorder.shared
    @State private var confirmResetAll = false
    private var store: ShortcutStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search shortcuts", text: $navigation.keyboardSearch)
                        .textFieldStyle(.plain)
                        .help("Filter by action name, key (e.g. ⌘E or P) or where it applies")
                    if !navigation.keyboardSearch.isEmpty {
                        Button { navigation.keyboardSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .iconHelp("Clear Search")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                Button("Reset All…") { confirmResetAll = true }
                    .disabled(store.overrides.isEmpty)
                    .help("Restore every shortcut to its default")
            }
            .padding(12)

            List {
                ForEach(ShortcutCategory.allCases, id: \.self) { category in
                    let actions = filtered(category)
                    if !actions.isEmpty {
                        Section(category.rawValue) {
                            ForEach(actions) { action in
                                ShortcutRow(action: action, recorder: recorder)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ removes the shortcut. Keys without ⌘ never fire while you type in a text field.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 600, minHeight: 520)
        .onDisappear { recorder.stop() }
        .confirmationDialog("Reset all keyboard shortcuts to their defaults?", isPresented: $confirmResetAll) {
            Button("Reset All", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func filtered(_ category: ShortcutCategory) -> [ShortcutAction] {
        let q = navigation.keyboardSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutAction.allCases.filter { a in
            guard a.category == category else { return false }
            guard !q.isEmpty else { return true }
            let key = store.display(a).lowercased()
            return a.title.lowercased().contains(q) || key == q || (q.count > 1 && key.contains(q))
                || a.scope.title.lowercased().contains(q) || a.category.rawValue.lowercased() == q
        }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let recorder: ShortcutRecorder
    private var store: ShortcutStore { .shared }

    var body: some View {
        let conflicts = store.conflicts(of: action)
        let overridden = store.overridden(by: action)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                    Text(subtitle(overridden))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !conflicts.isEmpty, recorder.pending?.action != action {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .iconHelp("Conflicts with \(names(conflicts))")
                }
                recordButton
                Button { store.reset(action) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(!store.isCustomized(action))
                    .opacity(store.isCustomized(action) ? 1 : 0.35)
                    .iconHelp("Reset to Default (\(action.defaultBinding?.display ?? "none"))")
            }
            if let pending = recorder.pending, pending.action == action {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("\(pending.combo.display) is already used by \(names(pending.conflicts)).")
                        .font(.callout)
                    Spacer()
                    Button("Reassign") { recorder.confirmPending() }
                        .help("Use \(pending.combo.display) for \(action.title) and remove it from \(names(pending.conflicts))")
                    Button("Cancel") { recorder.pending = nil }
                        .help("Keep the current shortcuts")
                }
                .controlSize(.small)
            } else if !conflicts.isEmpty {
                HStack(spacing: 6) {
                    Text("Also used by \(names(conflicts)) in an overlapping context.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    if let combo = store.binding(for: action) {
                        Button("Reassign") { store.reassign(combo, to: action) }
                            .controlSize(.small)
                            .help("Keep \(combo.display) for \(action.title) only")
                    }
                }
            }
            if let message = recorder.message, recorder.messageAction == action {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var recordButton: some View {
        let isRecording = recorder.recording == action
        let text = isRecording ? "Type Shortcut…" : (store.binding(for: action)?.display ?? "None")
        return Button { recorder.toggle(action) } label: {
            Text(text)
                .font(isRecording ? .callout : .body.monospaced())
                .foregroundStyle(store.binding(for: action) == nil && !isRecording ? .secondary : .primary)
                .frame(minWidth: 96)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(isRecording ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the new shortcut (Esc cancels, ⌫ removes the shortcut)" : "Click to record a new shortcut for \(action.title)")
        .accessibilityLabel("Shortcut for \(action.title): \(store.binding(for: action)?.display ?? "none")")
    }

    private func subtitle(_ overridden: [ShortcutAction]) -> String {
        var s = action.scope.title
        if !overridden.isEmpty { s += " · overrides \(names(overridden)) here" }
        return s
    }

    private func names(_ actions: [ShortcutAction]) -> String {
        actions.map(\.title).joined(separator: ", ")
    }
}

/// Key capture for the Keyboard settings: one action at a time, via a local monitor that
/// consumes every key press while recording (so menu shortcuts don't fire).
@Observable
final class ShortcutRecorder {
    static let shared = ShortcutRecorder()

    struct Pending {
        let action: ShortcutAction
        let combo: KeyCombo
        let conflicts: [ShortcutAction]
    }

    private(set) var recording: ShortcutAction?
    var pending: Pending?
    private(set) var message: String?
    private(set) var messageAction: ShortcutAction?
    @ObservationIgnored private var monitor: Any?

    func toggle(_ action: ShortcutAction) {
        if recording == action { stop() } else { start(action) }
    }

    func start(_ action: ShortcutAction) {
        pending = nil
        message = nil
        recording = action
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { ShortcutRecorder.shared.capture(event) }
            return consumed ? nil : event
        }
    }

    func stop() {
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func confirmPending() {
        guard let p = pending else { return }
        ShortcutStore.shared.reassign(p.combo, to: p.action)
        pending = nil
    }

    /// Handles a key press while recording. Returns true = consumed.
    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard let action = recording, let combo = KeyCombo(event: event) else { return false }
        return record(combo, for: action)
    }

    /// Applies a recorded key press (also used by DevScript).
    @discardableResult
    func record(_ combo: KeyCombo, for action: ShortcutAction) -> Bool {
        let store = ShortcutStore.shared
        if combo.modifiers.isEmpty && combo.key == "escape" { stop(); return true }
        if combo.modifiers.isEmpty && (combo.key == "delete" || combo.key == "forwarddelete") {
            store.setBinding(nil, for: action)
            stop()
            return true
        }
        if combo.isReserved {
            message = "\(combo.display) is reserved by macOS."
            messageAction = action
            NSSound.beep()
            return true
        }
        message = nil
        stop()
        let conflicts = store.conflicts(for: combo, action: action)
        if conflicts.isEmpty {
            store.setBinding(combo, for: action)
        } else {
            pending = Pending(action: action, combo: combo, conflicts: conflicts)
        }
        return true
    }
}
