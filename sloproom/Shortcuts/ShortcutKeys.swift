//
//  ShortcutKeys.swift
//  sloproom
//
//  AppKit / SwiftUI side of the shortcut registry.
//
//  Two ways a shortcut is performed:
//  1. Menu commands (`ShortcutAction.isMenuCommand`, scope "Everywhere"): `ShortcutMenuButton`
//     puts the user's binding on the menu item (`.keyboardShortcut`), so menus always show the
//     current key. Keys without ⌘/⌃ that are pressed while a text field is edited are typed
//     into the field instead (TextInputGuard).
//  2. Everything else: views register `ShortcutHandler`s (`.shortcutHandlers(id:) { … }`) with
//     `ShortcutDispatcher`, ONE local key monitor on the main window + full-screen preview.
//     Local monitors see keys before menu key equivalents. For a key press the dispatcher
//     computes the context (Library / Develop / crop / mask / WB selector / full screen), asks
//     the store for the candidate actions (narrowest scope first) and performs the first one
//     whose handler is available (e.g. grid focused); if the first match is a menu command it
//     lets the menu have the key. It yields while a text field is edited, a sheet is up, or the
//     key window is another window (Settings, panels).
//     A handler may also be registered for a menu command when AppKit would swallow the key
//     (D = Develop: AppKit's Start Dictation takes plain D; ⌘A: Edit > Select All).
//

import AppKit
import SwiftUI

// MARK: - NSEvent / SwiftUI conversions

extension KeyCombo {
    /// Hardware key codes of non-printing keys.
    static let keyCodeNames: [UInt16: String] = [
        36: "return", 76: "return", 53: "escape", 51: "delete", 117: "forwarddelete", 48: "tab", 49: "space",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12",
    ]

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    /// The key press of a keyDown / keyUp event. Printable keys use the character the key
    /// produces WITHOUT modifiers (⇧[ → "[" + ⇧, ⌥P → "p" + ⌥).
    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let mods = Self.modifiers(event.modifierFlags)
        if let name = Self.keyCodeNames[event.keyCode] {
            self.init(name, mods)
            return
        }
        let ignoring = event.charactersIgnoringModifiers ?? ""
        var base = event.characters(byApplyingModifiers: []) ?? ""
        // Synthesized events can carry characters that don't match their key code: trust the
        // event's own characters when no ⇧ could explain the difference.
        if base.isEmpty || (!mods.contains(.shift) && !ignoring.isEmpty && ignoring.lowercased() != base.lowercased()) {
            base = ignoring
        }
        guard let c = base.first, !c.isNewline, c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) else { return nil }
        self.init(String(c), mods)
    }

    /// ⇧ + key typed a different character that is bound without ⇧ (e.g. ⇧⌘0 = "⌘=" on a German
    /// layout): that character with the remaining modifiers.
    static func shiftedAlternative(of event: NSEvent, primary: KeyCombo) -> KeyCombo? {
        guard primary.modifiers.contains(.shift), !primary.isSpecialKey,
              let typed = event.charactersIgnoringModifiers?.first,
              typed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0xF700 }) else { return nil }
        let alt = KeyCombo(String(typed), primary.modifiers.subtracting(.shift))
        return alt.key == primary.key ? nil : alt
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": return .return
        case "escape": return .escape
        case "delete": return .delete
        case "forwarddelete": return .deleteForward
        case "tab": return .tab
        case "space": return .space
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n),
               let scalar = UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(n - 1)) {
                return KeyEquivalent(Character(scalar))
            }
            return KeyEquivalent(Character(key))
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    /// Keys macOS / the app menu own; the recorder refuses them.
    var isReserved: Bool {
        guard modifiers == .command else { return false }
        return ["q", "w", "h", "m", ",", "`", "tab", "space"].contains(key)
    }
}

// MARK: - Menu items

/// A menu item for a registry action: the title and the user's current shortcut.
struct ShortcutMenuButton: View {
    let action: ShortcutAction
    var title: String?
    let perform: () -> Void

    init(_ action: ShortcutAction, title: String? = nil, perform: @escaping () -> Void) {
        self.action = action
        self.title = title
        self.perform = perform
    }

    var body: some View {
        let combo = ShortcutStore.shared.binding(for: action)
        Button(title ?? action.title) {
            if let combo, TextInputGuard.forwardIfTyping(combo) { return }
            perform()
        }
        .keyboardShortcut(combo?.keyboardShortcut)
        .onAppear { ShortcutMenuSync.register(title ?? action.title, action) }
    }
}

/// A menu toggle for a registry action.
struct ShortcutMenuToggle: View {
    let action: ShortcutAction
    @Binding var isOn: Bool

    var body: some View {
        let combo = ShortcutStore.shared.binding(for: action)
        Toggle(action.title, isOn: Binding(get: { isOn }, set: { v in
            if let combo, TextInputGuard.forwardIfTyping(combo) { return }
            isOn = v
        }))
        .keyboardShortcut(combo?.keyboardShortcut)
        .onAppear { ShortcutMenuSync.register(action.title, action) }
    }
}

/// Keeps the menu bar's key equivalents equal to the user's bindings. SwiftUI builds menu items
/// with the binding at launch but doesn't update an existing NSMenuItem's key equivalent when
/// the Commands re-render, so after every store change the items of registry actions (found by
/// title; `ShortcutMenuButton` registers them) are patched directly.
enum ShortcutMenuSync {
    private static var titles: [String: ShortcutAction] = [:]
    private static var observer: NSObjectProtocol?

    static func register(_ title: String, _ action: ShortcutAction) {
        titles[title] = action
    }

    static func start() {
        guard observer == nil else { return }
        // Menu item views may not have appeared yet: seed with the default titles.
        for action in ShortcutAction.allCases where action.isMenuCommand && titles[action.title] == nil {
            titles[action.title] = action
        }
        for stars in 0...5 { titles[stars == 0 ? "None" : String(repeating: "★", count: stars)] = .rating(stars) }
        observer = NotificationCenter.default.addObserver(forName: ShortcutStore.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    /// Sets every registry menu item's key equivalent from the store.
    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        for top in main.items { if let sub = top.submenu { apply(sub) } }
    }

    private static func apply(_ menu: NSMenu) {
        for item in menu.items {
            if let sub = item.submenu { apply(sub); continue }
            guard let action = titles[item.title], action.isMenuCommand else { continue }
            let combo = ShortcutStore.shared.binding(for: action)
            let key = combo?.menuKeyEquivalent ?? ""
            let mask = combo.map { NSEvent.ModifierFlags(keyModifiers: $0.modifiers) } ?? []
            if item.keyEquivalent != key { item.keyEquivalent = key }
            if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
        }
    }
}

extension NSEvent.ModifierFlags {
    init(keyModifiers m: KeyModifiers) {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        self = f
    }
}

extension KeyCombo {
    /// NSMenuItem.keyEquivalent string.
    var menuKeyEquivalent: String {
        func fn(_ c: Int) -> String { String(UnicodeScalar(UInt32(c)).map(Character.init) ?? " ") }
        switch key {
        case "return": return "\r"
        case "escape": return "\u{1b}"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case "forwarddelete": return "\u{7f}"
        case "left": return fn(NSLeftArrowFunctionKey)
        case "right": return fn(NSRightArrowFunctionKey)
        case "up": return fn(NSUpArrowFunctionKey)
        case "down": return fn(NSDownArrowFunctionKey)
        case "home": return fn(NSHomeFunctionKey)
        case "end": return fn(NSEndFunctionKey)
        case "pageup": return fn(NSPageUpFunctionKey)
        case "pagedown": return fn(NSPageDownFunctionKey)
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) { return fn(NSF1FunctionKey + n - 1) }
            return key
        }
    }
}

extension TextInputGuard {
    /// Menu key equivalents are matched before the field editor sees plain letters: when the
    /// menu item was triggered by typing `combo` (no ⌘ / ⌃) into a text field, types the key's
    /// characters into the field and returns true.
    static func forwardIfTyping(_ combo: KeyCombo) -> Bool {
        guard combo.typesCharacter, let event = NSApp.currentEvent, event.type == .keyDown,
              KeyCombo(event: event).map({ combo.accepts($0) }) == true else { return false }
        return forwardIfEditing(event.characters ?? combo.key)
    }
}

// MARK: - Tooltips

extension View {
    /// Tooltip with the action's current shortcut ("Pick (P)"); follows rebinding.
    func help(_ text: String, shortcut action: ShortcutAction?) -> some View {
        help(ShortcutStore.shared.help(text, action))
    }

    /// Icon-only control: tooltip (with shortcut) + accessibility label.
    func iconHelp(_ text: String, shortcut action: ShortcutAction? = nil) -> some View {
        help(ShortcutStore.shared.help(text, action)).accessibilityLabel(text)
    }
}

// MARK: - Dispatcher

struct ShortcutHandler {
    let action: ShortcutAction
    /// Whether this handler can take the key right now (focus, tool state, event window…).
    var isAvailable: @MainActor (NSEvent) -> Bool = { _ in true }
    let perform: @MainActor (NSEvent) -> Void
    /// Called on key-up of the key that triggered it (held keys: Space = hand tool).
    var release: (@MainActor () -> Void)?

    init(_ action: ShortcutAction, when isAvailable: @escaping @MainActor (NSEvent) -> Bool = { _ in true },
         release: (@MainActor () -> Void)? = nil, perform: @escaping @MainActor (NSEvent) -> Void) {
        self.action = action
        self.isAvailable = isAvailable
        self.perform = perform
        self.release = release
    }
}

final class ShortcutDispatcher {
    static let shared = ShortcutDispatcher()

    weak var model: AppModel?
    /// The main window (set by MainWindowView). Keys of other windows (Settings) are ignored.
    weak var mainWindow: NSWindow?
    private var monitor: Any?
    private var registrations: [(token: UUID, handlers: [ShortcutHandler])] = []
    /// Key code → release of a held key.
    private var held: [UInt16: ShortcutHandler] = [:]
    /// Last dispatch, for DevScript diagnostics.
    private(set) var lastDispatch = ""

    func install(model: AppModel) {
        self.model = model
        ShortcutMenuSync.start()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            let handled = MainActor.assumeIsolated { ShortcutDispatcher.shared.handle(event) }
            return handled ? nil : event
        }
    }

    func register(_ token: UUID, _ handlers: [ShortcutHandler]) {
        registrations.removeAll { $0.token == token }
        registrations.append((token, handlers))
    }

    func unregister(_ token: UUID) {
        registrations.removeAll { $0.token == token }
    }

    func handlers(for action: ShortcutAction) -> [ShortcutHandler] {
        registrations.flatMap { $0.handlers.filter { $0.action == action } }
    }

    var registeredActions: Set<ShortcutAction> { Set(registrations.flatMap { $0.handlers.map(\.action) }) }

    /// The context of a key event, or nil when shortcuts must not run (text editing, sheets,
    /// other windows).
    func context(for event: NSEvent) -> ShortcutContext? {
        guard let window = event.window, window.attachedSheet == nil, !window.isSheet,
              !TextInputGuard.isEditing(in: window) else { return nil }
        let fs = FullScreenPreview.shared
        if fs.isShowing, window === fs.window { return .fullScreen }
        guard !(window is NSPanel), mainWindow == nil || window === mainWindow, let model else { return nil }
        guard model.mode == .develop else { return .library }
        guard let session = model.developSession else { return .develop }
        if session.isPickingWhiteBalance { return .whiteBalance }
        switch session.activeTool {
        case .crop: return .crop
        case .mask: return .mask
        case .none: return .develop
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            guard let handler = held.removeValue(forKey: event.keyCode) else { return false }
            handler.release?()
            return true
        }
        guard let context = context(for: event), let primary = KeyCombo(event: event) else { return false }
        let store = ShortcutStore.shared
        var combo = primary
        var candidates = store.candidates(for: combo, in: context)
        // Layouts where the bound character needs ⇧ (German ⌘= is ⇧⌘0): match the typed character too.
        if candidates.isEmpty, let alt = KeyCombo.shiftedAlternative(of: event, primary: primary) {
            combo = alt
            candidates = store.candidates(for: alt, in: context)
        }
        for action in candidates {
            if let handler = handlers(for: action).first(where: { $0.isAvailable(event) }) {
                lastDispatch = "\(combo.display) → \(action.id) in \(context.rawValue)"
                if event.isARepeat && !action.repeats { return true }   // swallow: never falls through to a menu item
                handler.perform(event)
                if handler.release != nil { held[event.keyCode] = handler }
                return true
            }
            if action.isMenuCommand {
                lastDispatch = "\(combo.display) → menu \(action.id) in \(context.rawValue)"
                return false
            }
        }
        if !candidates.isEmpty {
            lastDispatch = "\(combo.display) → no available handler for \(candidates.map(\.id)) in \(context.rawValue)"
        }
        return false
    }

    /// Forgets held keys (their key-up may never arrive, e.g. when the app deactivates).
    func releaseHeldKeys() {
        let handlers = held.values
        held.removeAll()
        for h in handlers { h.release?() }
    }
}

extension TextInputGuard {
    static func isEditing(in window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.isEditable ?? false
    }
}

extension View {
    /// Registers shortcut handlers with the dispatcher while this view is on screen. `id`
    /// re-registers when it changes (e.g. the develop session); handlers should capture
    /// objects (model, session, controllers), not view values.
    func shortcutHandlers(id: AnyHashable = 0, _ make: @escaping @MainActor () -> [ShortcutHandler]) -> some View {
        modifier(ShortcutHandlerRegistration(id: id, make: make))
    }

    /// Installs the dispatcher (once, on the main window) and records the main window.
    func shortcutDispatcher(model: AppModel) -> some View {
        background(WindowReader { window in
            if let window { ShortcutDispatcher.shared.mainWindow = window }
        })
        .onAppear { ShortcutDispatcher.shared.install(model: model) }
    }
}

private struct ShortcutHandlerRegistration: ViewModifier {
    let id: AnyHashable
    let make: @MainActor () -> [ShortcutHandler]
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { ShortcutDispatcher.shared.register(token, make()) }
            .onDisappear { ShortcutDispatcher.shared.unregister(token) }
            .onChange(of: id) { _, _ in ShortcutDispatcher.shared.register(token, make()) }
    }
}

/// A reference box for view state that handlers read (e.g. whether the grid has focus).
final class ShortcutFlag {
    var value = false
}
