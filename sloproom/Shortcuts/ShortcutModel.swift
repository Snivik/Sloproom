//
//  ShortcutModel.swift
//  sloproom
//
//  The keyboard shortcut registry's vocabulary (UI-free, compiled by Tools/shortcuts_check.swift):
//
//  - `KeyCombo`: a key + modifiers, parsed from / written as a spec string ("cmd+shift+e",
//    "p", "escape", "cmd+=") and shown as a glyph string ("⇧⌘E", "P", "⎋", "⌘=").
//  - `ShortcutContext`: the ONE state the app is in when a key arrives (Library, Develop, crop
//    tool, mask tool, white-balance picker, full-screen preview). Computed per key event.
//  - `ShortcutScope`: where an action is active = a set of contexts. The same key may mean
//    different things in scopes that don't overlap (⌘= = thumbnails in Library, zoom in Develop)
//    and a NARROWER scope overrides a broader one (X = Swap Aspect in Crop overrides X = Reject
//    everywhere). Two bindings conflict only when their scopes overlap and neither is strictly
//    narrower than the other (e.g. both global).
//  - `ShortcutAction`: every command that has (or can have) a shortcut, with a stable string id
//    (persisted), display name, category, scope and default binding.
//

import Foundation

// MARK: - Key combos

nonisolated struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    /// Glyphs in the standard macOS order (⌃⌥⇧⌘).
    var glyphs: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

nonisolated struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    /// A printable character, lowercased ("p", "=", "[", "\\", "1"), or a special key name
    /// (`KeyCombo.specialKeys`: "return", "escape", "delete", "tab", "space", "left", "f1", …).
    var key: String
    var modifiers: KeyModifiers

    init(_ key: String, _ modifiers: KeyModifiers = []) {
        self.key = KeyCombo.normalizedKey(key)
        self.modifiers = modifiers
    }

    /// Special (non-printing) key names → display glyph.
    static let specialKeys: [String: String] = [
        "return": "↩", "escape": "⎋", "delete": "⌫", "forwarddelete": "⌦", "tab": "⇥", "space": "Space",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6",
        "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]

    var isSpecialKey: Bool { Self.specialKeys[key] != nil }

    /// A plain key (no ⌘ / ⌃) that types a character — must yield to text fields.
    var typesCharacter: Bool {
        !modifiers.contains(.command) && !modifiers.contains(.control) && (!isSpecialKey || key == "space")
    }

    static func normalizedKey(_ key: String) -> String {
        let lower = key.lowercased()
        switch lower {
        case " ": return "space"
        case "\r", "enter": return "return"
        case "esc": return "escape"
        case "backspace": return "delete"
        case "+": return "="            // ⌘+ is ⌘⇧= on most layouts
        case "_": return "-"
        default: return lower
        }
    }

    /// "⇧⌘E", "P", "⌘=", "⎋", "Space".
    var display: String {
        let k: String
        if let glyph = Self.specialKeys[key] { k = glyph } else { k = key.uppercased() }
        return modifiers.glyphs + k
    }

    var description: String { display }

    /// Spec string: modifiers "ctrl+opt+shift+cmd+" then the key ("cmd+shift+e", "=", "escape").
    var spec: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key == "+" ? "plus" : key)
        return parts.joined(separator: "+")
    }

    /// Parses a spec ("cmd+shift+e", "shift+tab", "k", "cmd+=", "cmd+plus", "=", "+").
    init?(spec: String) {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s == "+" { self.init("=", []); return }
        var parts = s.split(separator: "+", omittingEmptySubsequences: false).map { String($0).lowercased() }
        // A trailing "+" key ("cmd++") splits into an empty last part.
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
        guard let rawKey = parts.popLast(), !rawKey.isEmpty else { return nil }
        var mods: KeyModifiers = []
        for m in parts {
            switch m {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            default: return nil
            }
        }
        let key = rawKey == "plus" ? "=" : KeyCombo.normalizedKey(rawKey)
        guard key.count == 1 || Self.specialKeys[key] != nil else { return nil }
        self.init(key, mods)
    }

    /// Whether a key press `event` triggers a binding of `self`. Besides exact equality:
    /// - "=" / "-" bindings without ⇧ also accept ⇧ (⌘= also fires on ⌘+ = ⌘⇧=, ⌘- on ⌘_),
    /// - "delete" (⌫) also accepts forward delete (⌦),
    /// - `extraShift`: ⇧ may be added (grid arrows: ⇧ extends the selection).
    func accepts(_ event: KeyCombo, extraShift: Bool = false) -> Bool {
        var e = event
        if key == "delete", e.key == "forwarddelete" { e.key = "delete" }
        guard e.key == key else { return false }
        if e.modifiers == modifiers { return true }
        let shiftTolerant = extraShift || key == "=" || key == "-"
        return shiftTolerant && !modifiers.contains(.shift) && e.modifiers == modifiers.union(.shift)
    }

    /// Two bindings that some key press would trigger both of.
    func overlaps(_ other: KeyCombo) -> Bool { accepts(other) || other.accepts(self) }
}

// MARK: - Contexts and scopes

/// The state the app is in when a key arrives (exactly one).
nonisolated enum ShortcutContext: String, CaseIterable, Sendable {
    case library, develop, crop, mask, whiteBalance, fullScreen
}

nonisolated enum ShortcutScope: String, CaseIterable, Sendable {
    /// Everywhere (menu bar key equivalents).
    case global
    /// The main window, Library and Develop (not the full-screen preview).
    case mainWindow
    case library
    /// Develop, including its tools.
    case develop
    /// Develop canvas and the full-screen preview (zoom, previous / next photo).
    case viewer
    case crop
    case mask
    case whiteBalance
    case fullScreen

    var contexts: Set<ShortcutContext> {
        switch self {
        case .global: return Set(ShortcutContext.allCases)
        case .mainWindow: return [.library, .develop, .crop, .mask, .whiteBalance]
        case .library: return [.library]
        case .develop: return [.develop, .crop, .mask, .whiteBalance]
        case .viewer: return [.develop, .crop, .mask, .whiteBalance, .fullScreen]
        case .crop: return [.crop]
        case .mask: return [.mask]
        case .whiteBalance: return [.whiteBalance]
        case .fullScreen: return [.fullScreen]
        }
    }

    var title: String {
        switch self {
        case .global: return "Everywhere"
        case .mainWindow: return "Library & Develop"
        case .library: return "Library"
        case .develop: return "Develop"
        case .viewer: return "Develop & Full Screen"
        case .crop: return "Crop Tool"
        case .mask: return "Mask Tool"
        case .whiteBalance: return "White Balance Selector"
        case .fullScreen: return "Full Screen Preview"
        }
    }

    func overlaps(_ other: ShortcutScope) -> Bool { !contexts.isDisjoint(with: other.contexts) }

    /// Strictly narrower: active in fewer contexts, all of which `other` covers (overrides it there).
    func isNarrower(than other: ShortcutScope) -> Bool {
        contexts.isStrictSubset(of: other.contexts)
    }

    /// Same key in both scopes is ambiguous somewhere (overlap without one overriding the other).
    func conflicts(with other: ShortcutScope) -> Bool {
        overlaps(other) && !isNarrower(than: other) && !other.isNarrower(than: self)
    }
}

// MARK: - Actions

nonisolated enum ShortcutCategory: String, CaseIterable, Sendable {
    case file = "File", edit = "Edit", photo = "Photo", view = "View", library = "Library",
         develop = "Develop", crop = "Crop", masks = "Masks"
}

nonisolated enum ShortcutAction: String, CaseIterable, Sendable, Identifiable {
    // File
    case newFolder, importPhotos, importLightroomCatalog, exportPhotos, exportCatalog, importCatalog
    // Edit
    case undo, redo, selectAllPhotos
    // Photo
    case pick, unflag, reject, autoAdvance
    case rating0, rating1, rating2, rating3, rating4, rating5
    case copySettings, pasteSettings, beforeAfter
    case createVirtualCopy
    case bulkCrop, syncSettings, resetEdits, showInFinder   // photo actions (Actions/)
    // View
    case libraryMode, developMode, fullScreenPreview, exitFullScreen, toggleSidePanels, toggleAllPanels
    case zoomToggle, zoomIn, zoomOut, temporaryHand, keyboardShortcuts
    case toggleSidebar, zoomFit
    // Library
    case thumbnailLarger, thumbnailSmaller, moveLeft, moveRight, moveUp, moveDown, openInDevelop,
         removePhotos, deleteFolder
    // Develop
    case previousPhoto, nextPhoto, toggleCropTool, rotateLeft, rotateRight, cancelWhiteBalance
    // Crop
    case cropSwapAspect, cropGridOverlay, cropCommit, cropCancel
    // Masks
    case maskOverlay, brushSmaller, brushLarger, deleteMask, maskCancel

    /// Stable id (persisted in UserDefaults overrides; never rename a case without migrating).
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newFolder: return "New Folder"
        case .importPhotos: return "Import Photos…"
        case .importLightroomCatalog: return "Import Lightroom Catalog…"
        case .exportPhotos: return "Export…"
        case .exportCatalog: return "Export Catalog…"
        case .importCatalog: return "Import Catalog…"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .selectAllPhotos: return "Select All Photos"
        case .pick: return "Pick"
        case .unflag: return "Unflag"
        case .reject: return "Reject"
        case .autoAdvance: return "Auto Advance After Flagging"
        case .rating0: return "Rating: None"
        case .rating1, .rating2, .rating3, .rating4, .rating5: return "Rating: " + String(repeating: "★", count: rating ?? 0)
        case .copySettings: return "Copy Settings"
        case .pasteSettings: return "Paste Settings"
        case .beforeAfter: return "Before / After"
        case .createVirtualCopy: return "Create Virtual Copy"
        case .bulkCrop: return "Bulk Crop…"
        case .syncSettings: return "Sync Settings…"
        case .resetEdits: return "Reset Edits"
        case .showInFinder: return "Show in Finder"
        case .libraryMode: return "Library"
        case .developMode: return "Develop"
        case .fullScreenPreview: return "Full Screen Preview"
        case .exitFullScreen: return "Close Full Screen Preview"
        case .toggleSidePanels: return "Show / Hide Side Panels"
        case .toggleAllPanels: return "Show / Hide All Panels"
        case .zoomToggle: return "Zoom Fit ↔ 1:1"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomFit: return "Zoom to Fit"
        case .toggleSidebar: return "Show / Hide Folders"
        case .temporaryHand: return "Hand Tool (hold)"
        case .keyboardShortcuts: return "Keyboard Shortcuts…"
        case .thumbnailLarger: return "Increase Thumbnail Size"
        case .thumbnailSmaller: return "Decrease Thumbnail Size"
        case .moveLeft: return "Select Previous Photo"
        case .moveRight: return "Select Next Photo"
        case .moveUp: return "Select Photo Above"
        case .moveDown: return "Select Photo Below"
        case .openInDevelop: return "Open in Develop"
        case .removePhotos: return "Remove from Folder / Catalog"
        case .deleteFolder: return "Delete Folder (sidebar)"
        case .previousPhoto: return "Previous Photo"
        case .nextPhoto: return "Next Photo"
        case .toggleCropTool: return "Crop Tool"
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .cancelWhiteBalance: return "Cancel White Balance Selector"
        case .cropSwapAspect: return "Swap Portrait / Landscape"
        case .cropGridOverlay: return "Cycle Grid Overlay"
        case .cropCommit: return "Done (Keep Crop)"
        case .cropCancel: return "Cancel Crop"
        case .maskOverlay: return "Show / Hide Mask Overlay"
        case .brushSmaller: return "Decrease Brush Size"
        case .brushLarger: return "Increase Brush Size"
        case .deleteMask: return "Delete Selected Mask"
        case .maskCancel: return "Cancel Mask / Leave Mask Tool"
        }
    }

    /// Stars for the rating actions.
    var rating: Int? {
        switch self {
        case .rating0: return 0
        case .rating1: return 1
        case .rating2: return 2
        case .rating3: return 3
        case .rating4: return 4
        case .rating5: return 5
        default: return nil
        }
    }

    static func rating(_ stars: Int) -> ShortcutAction {
        [.rating0, .rating1, .rating2, .rating3, .rating4, .rating5][min(max(stars, 0), 5)]
    }

    var category: ShortcutCategory {
        switch self {
        case .newFolder, .importPhotos, .importLightroomCatalog, .exportPhotos, .exportCatalog, .importCatalog: return .file
        case .undo, .redo, .selectAllPhotos: return .edit
        case .pick, .unflag, .reject, .autoAdvance, .rating0, .rating1, .rating2, .rating3, .rating4, .rating5,
             .copySettings, .pasteSettings, .beforeAfter, .createVirtualCopy,
             .bulkCrop, .syncSettings, .resetEdits, .showInFinder: return .photo
        case .libraryMode, .developMode, .fullScreenPreview, .exitFullScreen, .toggleSidePanels, .toggleAllPanels,
             .zoomToggle, .zoomIn, .zoomOut, .temporaryHand, .keyboardShortcuts, .toggleSidebar, .zoomFit: return .view
        case .thumbnailLarger, .thumbnailSmaller, .moveLeft, .moveRight, .moveUp, .moveDown, .openInDevelop,
             .removePhotos, .deleteFolder: return .library
        case .previousPhoto, .nextPhoto, .toggleCropTool, .rotateLeft, .rotateRight, .cancelWhiteBalance: return .develop
        case .cropSwapAspect, .cropGridOverlay, .cropCommit, .cropCancel: return .crop
        case .maskOverlay, .brushSmaller, .brushLarger, .deleteMask, .maskCancel: return .masks
        }
    }

    var scope: ShortcutScope {
        switch self {
        case .selectAllPhotos, .deleteFolder: return .mainWindow
        case .thumbnailLarger, .thumbnailSmaller, .moveLeft, .moveRight, .moveUp, .moveDown, .openInDevelop, .removePhotos:
            return .library
        case .toggleSidePanels, .toggleAllPanels, .toggleCropTool, .rotateLeft, .rotateRight: return .develop
        case .zoomToggle, .zoomIn, .zoomOut, .zoomFit, .temporaryHand, .previousPhoto, .nextPhoto: return .viewer
        case .exitFullScreen: return .fullScreen
        case .cancelWhiteBalance: return .whiteBalance
        case .cropSwapAspect, .cropGridOverlay, .cropCommit, .cropCancel: return .crop
        case .maskOverlay, .brushSmaller, .brushLarger, .deleteMask, .maskCancel: return .mask
        default: return .global
        }
    }

    /// Holding the key repeats the action (otherwise auto-repeats are swallowed).
    var repeats: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown, .previousPhoto, .nextPhoto, .zoomIn, .zoomOut,
             .thumbnailLarger, .thumbnailSmaller, .brushSmaller, .brushLarger, .undo, .redo: return true
        default: return false
        }
    }

    /// ⇧ + the binding also triggers it (grid arrows: ⇧ extends the selection).
    var acceptsExtraShift: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown: return true
        default: return false
        }
    }

    var defaultBinding: KeyCombo? {
        switch self {
        case .newFolder: return KeyCombo("n", [.command, .shift])
        case .importPhotos: return KeyCombo("i", [.command, .shift])
        case .exportPhotos: return KeyCombo("e", [.command, .shift])
        case .importLightroomCatalog, .exportCatalog, .importCatalog, .autoAdvance, .keyboardShortcuts: return nil
        case .undo: return KeyCombo("z", .command)
        case .redo: return KeyCombo("z", [.command, .shift])
        case .selectAllPhotos: return KeyCombo("a", .command)
        case .pick: return KeyCombo("p")
        case .unflag: return KeyCombo("u")
        case .reject: return KeyCombo("x")
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5: return KeyCombo(String(rating ?? 0))
        case .copySettings: return KeyCombo("c", [.command, .shift])
        case .pasteSettings: return KeyCombo("v", [.command, .shift])
        case .beforeAfter: return KeyCombo("\\")
        case .createVirtualCopy: return KeyCombo("'", .command)
        case .bulkCrop: return nil
        case .syncSettings: return KeyCombo("s", [.command, .shift])     // Lightroom: Sync Settings
        case .resetEdits: return KeyCombo("r", [.command, .shift])       // Lightroom: Reset
        case .showInFinder: return KeyCombo("r", .command)               // Lightroom / Finder: Show in Finder
        case .libraryMode: return KeyCombo("g")
        case .developMode: return KeyCombo("d")
        case .fullScreenPreview: return KeyCombo("f")
        case .exitFullScreen: return KeyCombo("escape")
        case .toggleSidePanels: return KeyCombo("tab")
        case .toggleAllPanels: return KeyCombo("tab", .shift)
        case .zoomToggle: return KeyCombo("z")
        case .zoomIn, .thumbnailLarger: return KeyCombo("=", .command)
        case .zoomOut, .thumbnailSmaller: return KeyCombo("-", .command)
        case .zoomFit: return KeyCombo("0", .command)
        case .toggleSidebar: return KeyCombo("s", [.control, .command])   // macOS View > Show Sidebar
        case .temporaryHand: return KeyCombo("space")
        case .moveLeft, .previousPhoto: return KeyCombo("left")
        case .moveRight, .nextPhoto: return KeyCombo("right")
        case .moveUp: return KeyCombo("up")
        case .moveDown: return KeyCombo("down")
        case .openInDevelop, .cropCommit: return KeyCombo("return")
        case .removePhotos, .deleteFolder, .deleteMask: return KeyCombo("delete")
        case .toggleCropTool: return KeyCombo("r")
        case .rotateLeft: return KeyCombo("[", .command)
        case .rotateRight: return KeyCombo("]", .command)
        case .cancelWhiteBalance, .cropCancel, .maskCancel: return KeyCombo("escape")
        case .cropSwapAspect: return KeyCombo("x")
        case .cropGridOverlay, .maskOverlay: return KeyCombo("o")
        case .brushSmaller: return KeyCombo("[")
        case .brushLarger: return KeyCombo("]")
        }
    }

    /// A menu bar item performs it (menu key equivalent); other actions are performed by
    /// handlers registered with the key dispatcher (ShortcutKeys.swift).
    var isMenuCommand: Bool { scope == .global && self != .fullScreenPreview }

    /// Focus-bound actions: the same key does different things depending on which view has
    /// focus (grid vs sidebar), so they never conflict with each other.
    var focusGroup: String? {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown, .openInDevelop, .removePhotos: return "grid"
        case .deleteFolder: return "sidebar"
        default: return nil
        }
    }
}
