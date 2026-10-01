//
//  PhotoActionSpec.swift
//  sloproom
//
//  The photo actions primitive, UI-free part (compiled by Tools/actions_check.swift):
//
//  - `PhotoActionID`: every action that can be applied to one or more photos (stable ids).
//  - `PhotoActionSpec`: what an action declares — title (may depend on the number of targets:
//    "Pick 12 Photos"), SF Symbol, tooltip, ARITY (`.single` = exactly one target, `.multiple` =
//    one or more, `.many` = two or more), the modes it appears in (Library / Develop), an optional
//    shortcut (an action of the Shortcuts registry; the key itself always comes from the user's
//    bindings), the menu group it belongs to and whether it opens a folder submenu.
//  - `PhotoActionTargets.resolve`: THE target resolution (selection / right-clicked cell /
//    photo being edited), used by every surface.
//
//  The UI half (`PhotoActions.swift`) pairs each spec with `isEnabled` / `perform` closures that
//  touch the app model; menus are built from `PhotoActionSpec.all` (`PhotoActionMenus.swift`).
//

import Foundation

nonisolated enum PhotoActionID: String, CaseIterable, Sendable, Hashable {
    case openInDevelop, showInFinder
    case createVirtualCopy, renameVirtualCopy
    case pick, unflag, reject
    case copySettings, pasteSettings, pasteSettingsChoose, syncSettings, bulkCrop, resetEdits
    case addToFolder, moveToFolder, copyToFolder, newFolderWithPhotos, newFolderWithVirtualCopies, removeFromFolder
    case exportJPEG
    case removeFromCatalog
}

/// How many targets an action takes.
nonisolated enum PhotoActionArity: String, Sendable {
    /// Exactly one photo (Rename, Show in Finder, Copy Settings).
    case single
    /// One or more (Pick, Move to Folder, Bulk Crop).
    case multiple
    /// Two or more (Sync Settings: from one photo to the others).
    case many

    func accepts(_ count: Int) -> Bool {
        switch self {
        case .single: count == 1
        case .multiple: count >= 1
        case .many: count >= 2
        }
    }

    /// Tooltip of a disabled item when the count doesn't fit (nil when it does).
    func disabledReason(_ count: Int) -> String? {
        if accepts(count) { return nil }
        if count == 0 { return "Select a photo" }
        switch self {
        case .single: return "Select a single photo"
        case .multiple: return "Select a photo"
        case .many: return "Select two or more photos"
        }
    }
}

nonisolated struct PhotoActionModes: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let library = PhotoActionModes(rawValue: 1 << 0)
    static let develop = PhotoActionModes(rawValue: 1 << 1)
    static let both: PhotoActionModes = [.library, .develop]
}

/// Where the user is when the action is offered.
nonisolated enum PhotoActionMode: String, Sendable {
    case library, develop
    var modes: PhotoActionModes { self == .library ? .library : .develop }
}

/// Menu sections (a divider between groups).
nonisolated enum PhotoActionGroup: Int, CaseIterable, Sendable, Comparable {
    case open, virtualCopies, flags, edits, folders, export, removal
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The result of checking an action for a count of targets in a mode.
nonisolated enum PhotoActionAvailability: Equatable, Sendable {
    /// Not offered in this mode.
    case hidden
    /// Shown, greyed out, with a tooltip saying why.
    case disabled(String)
    case enabled

    var isEnabled: Bool { self == .enabled }
}

nonisolated struct PhotoActionSpec: Sendable, Identifiable {
    let id: PhotoActionID
    /// Static title: menu bar (its key equivalent is patched by title, so it never changes) and
    /// single-target menus.
    let menuTitle: String
    /// Title for `count` targets (context menus, Develop actions menu).
    let countTitle: @Sendable (Int) -> String
    let symbol: String
    let help: String
    let arity: PhotoActionArity
    let modes: PhotoActionModes
    /// Shortcuts registry action whose binding this action uses (tooltips, menu key equivalents).
    let shortcut: ShortcutAction?
    let group: PhotoActionGroup
    /// Opens a submenu of folders (Add to / Move to / Copy to Folder ▸).
    let isFolderMenu: Bool
    /// Offered in the menu bar's Photo menu (folder submenus and Export are not: Commands are not
    /// re-rendered on folder changes, and Export lives in the File menu).
    let inMenuBar: Bool

    init(_ id: PhotoActionID, _ menuTitle: String, count countTitle: (@Sendable (Int) -> String)? = nil,
         symbol: String, help: String, arity: PhotoActionArity, modes: PhotoActionModes = .both,
         shortcut: ShortcutAction? = nil, group: PhotoActionGroup, folderMenu: Bool = false, menuBar: Bool = true) {
        self.id = id
        self.menuTitle = menuTitle
        self.countTitle = countTitle ?? { _ in menuTitle }
        self.symbol = symbol
        self.help = help
        self.arity = arity
        self.modes = modes
        self.shortcut = shortcut
        self.group = group
        self.isFolderMenu = folderMenu
        self.inMenuBar = menuBar && !folderMenu
    }

    func title(count: Int) -> String { countTitle(max(count, 1)) }

    /// Arity + mode rules (the model-dependent part, e.g. "is there anything to paste", is added
    /// by the UI registry).
    func availability(count: Int, mode: PhotoActionMode) -> PhotoActionAvailability {
        guard modes.contains(mode.modes) else { return .hidden }
        if let reason = arity.disabledReason(count) { return .disabled(reason) }
        return .enabled
    }

    static func spec(_ id: PhotoActionID) -> PhotoActionSpec { byID[id]! }

    private static let byID: [PhotoActionID: PhotoActionSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func photos(_ n: Int) -> String { n == 1 ? "1 Photo" : "\(n) Photos" }

    /// The registry, in menu order.
    static let all: [PhotoActionSpec] = [
        PhotoActionSpec(.openInDevelop, "Open in Develop", symbol: "slider.horizontal.3",
                        help: "Edit this photo in Develop", arity: .single, modes: .library,
                        shortcut: .openInDevelop, group: .open),
        PhotoActionSpec(.showInFinder, "Show in Finder", symbol: "folder",
                        help: "Reveal the original file in the Finder", arity: .single,
                        shortcut: .showInFinder, group: .open),

        PhotoActionSpec(.createVirtualCopy, "Create Virtual Copy",
                        count: { $0 > 1 ? "Create \($0) Virtual Copies" : "Create Virtual Copy" },
                        symbol: "square.on.square",
                        help: "A new version of the photo with its own crop and edits; the file is not duplicated",
                        arity: .multiple, shortcut: .createVirtualCopy, group: .virtualCopies),
        PhotoActionSpec(.renameVirtualCopy, "Rename Virtual Copy…", symbol: "pencil",
                        help: "Name this copy (e.g. “Story”); shown in titles and export file names",
                        arity: .single, group: .virtualCopies),

        PhotoActionSpec(.pick, "Pick", count: { $0 > 1 ? "Pick \(photos($0))" : "Pick" }, symbol: "flag",
                        help: "Flag as a pick", arity: .multiple, shortcut: .pick, group: .flags),
        PhotoActionSpec(.unflag, "Unflag", count: { $0 > 1 ? "Unflag \(photos($0))" : "Unflag" }, symbol: "flag.slash",
                        help: "Remove the flag", arity: .multiple, shortcut: .unflag, group: .flags),
        PhotoActionSpec(.reject, "Reject", count: { $0 > 1 ? "Reject \(photos($0))" : "Reject" }, symbol: "xmark.circle",
                        help: "Flag as rejected", arity: .multiple, shortcut: .reject, group: .flags),

        PhotoActionSpec(.copySettings, "Copy Settings", symbol: "doc.on.doc",
                        help: "Copy the develop settings of the focused photo (Paste Settings applies them to other photos)",
                        arity: .multiple, shortcut: .copySettings, group: .edits),
        PhotoActionSpec(.pasteSettings, "Paste Settings",
                        count: { $0 > 1 ? "Paste Settings to \(photos($0))" : "Paste Settings" }, symbol: "doc.on.clipboard",
                        help: "Paste the copied settings (the sections chosen in “Choose Settings to Paste…”); one undo step",
                        arity: .multiple, shortcut: .pasteSettings, group: .edits),
        PhotoActionSpec(.pasteSettingsChoose, "Choose Settings to Paste…",
                        count: { $0 > 1 ? "Choose Settings to Paste to \(photos($0))…" : "Choose Settings to Paste…" },
                        symbol: "checklist",
                        help: "Pick which sections of the copied settings to paste (remembered for Paste Settings)",
                        arity: .multiple, group: .edits),
        PhotoActionSpec(.syncSettings, "Sync Settings…",
                        count: { $0 > 1 ? "Sync Settings to \(photos($0 - 1))…" : "Sync Settings…" },
                        symbol: "arrow.triangle.2.circlepath",
                        help: "Copy chosen sections of the focused photo's settings to the other selected photos; one undo step",
                        arity: .many, shortcut: .syncSettings, group: .edits),
        PhotoActionSpec(.bulkCrop, "Bulk Crop…",
                        count: { $0 > 1 ? "Bulk Crop \(photos($0))…" : "Bulk Crop…" }, symbol: "crop",
                        help: "Crop every photo to the same aspect ratio (centered, as large as fits); replaces existing crops; one undo step",
                        arity: .multiple, shortcut: .bulkCrop, group: .edits),
        PhotoActionSpec(.resetEdits, "Reset Edits",
                        count: { $0 > 1 ? "Reset Edits of \(photos($0))…" : "Reset Edits" }, symbol: "arrow.counterclockwise",
                        help: "Reset every adjustment, crop and mask; one undo step",
                        arity: .multiple, shortcut: .resetEdits, group: .edits),

        PhotoActionSpec(.addToFolder, "Add to Folder", symbol: "folder.badge.plus",
                        help: "Add to Folder: the same photo, edits shared (⌥-drag: copy, ⌘-drag: move)",
                        arity: .multiple, group: .folders, folderMenu: true),
        PhotoActionSpec(.moveToFolder, "Move to Folder", symbol: "folder",
                        help: "Move to Folder: take the photo out of this folder and put it in another",
                        arity: .multiple, group: .folders, folderMenu: true),
        PhotoActionSpec(.copyToFolder, "Copy to Folder", symbol: "square.on.square",
                        help: "Copy to Folder: an independent virtual copy with its own crop and edits (⌥-drag onto a folder)",
                        arity: .multiple, group: .folders, folderMenu: true),
        PhotoActionSpec(.newFolderWithPhotos, "New Folder with Photos",
                        count: { $0 == 1 ? "New Folder with Photo" : "New Folder with \($0) Photos" }, symbol: "folder.badge.plus",
                        help: "Creates a folder holding these photos (the same photos, edits shared)",
                        arity: .multiple, group: .folders),
        PhotoActionSpec(.newFolderWithVirtualCopies, "New Folder with Virtual Copies",
                        count: { $0 == 1 ? "New Folder with Virtual Copy" : "New Folder with Virtual Copies" },
                        symbol: "folder.badge.plus",
                        help: "Creates a folder holding independent virtual copies (own crop and edits) of the photos",
                        arity: .multiple, group: .folders),
        PhotoActionSpec(.removeFromFolder, "Remove from This Folder", symbol: "folder.badge.minus",
                        help: "Take the photos out of the folder shown (they stay in the catalog)",
                        arity: .multiple, shortcut: .removePhotos, group: .folders),

        PhotoActionSpec(.exportJPEG, "Export JPEG…", count: { "Export \(photos($0))…" }, symbol: "square.and.arrow.up",
                        help: "Export full-resolution JPEGs with the edits", arity: .multiple,
                        shortcut: .exportPhotos, group: .export, menuBar: false),

        PhotoActionSpec(.removeFromCatalog, "Remove from Catalog…", symbol: "trash",
                        help: "Remove from the catalog (asks first). The files on disk are not deleted",
                        arity: .multiple, group: .removal),
    ]
}

/// The photos an action applies to.
nonisolated struct PhotoActionTargets: Equatable, Sendable {
    /// In list order.
    var ids: [Int64]
    /// The "most selected" photo: the focused / edited photo if it is a target, else the first
    /// target (Sync Settings copies FROM it).
    var primaryID: Int64?
    var mode: PhotoActionMode
    /// A context menu was opened on a cell that is NOT part of the selection (acts on it alone).
    var clickedOutsideSelection = false

    var count: Int { ids.count }
    static let none = PhotoActionTargets(ids: [], primaryID: nil, mode: .library)

    /// THE target resolution, for every surface:
    /// - Library: the selection (list order), else the focused photo; a context menu on a cell
    ///   that is not selected acts on that cell only.
    /// - Develop: the filmstrip selection if more than one photo is selected (and the edited
    ///   photo is one of them), else the photo being edited; a context menu on a filmstrip cell
    ///   acts on the selection if the cell is part of a multi-selection, else on that cell.
    static func resolve(mode: PhotoActionMode, orderedSelection: [Int64], focusedID: Int64?, clickedID: Int64? = nil) -> PhotoActionTargets {
        let selected = Set(orderedSelection)
        func primary(_ ids: [Int64]) -> Int64? {
            if let f = focusedID, ids.contains(f) { return f }
            if let c = clickedID, ids.contains(c) { return c }
            return ids.first
        }
        if let clicked = clickedID {
            guard selected.contains(clicked) else {
                return PhotoActionTargets(ids: [clicked], primaryID: clicked, mode: mode, clickedOutsideSelection: true)
            }
            let ids = (mode == .library || orderedSelection.count > 1) ? orderedSelection : [clicked]
            return PhotoActionTargets(ids: ids, primaryID: primary(ids), mode: mode)
        }
        switch mode {
        case .library:
            let ids = orderedSelection.isEmpty ? (focusedID.map { [$0] } ?? []) : orderedSelection
            return PhotoActionTargets(ids: ids, primaryID: primary(ids), mode: mode)
        case .develop:
            guard let focused = focusedID else { return PhotoActionTargets(ids: [], primaryID: nil, mode: mode) }
            let ids = orderedSelection.count > 1 && selected.contains(focused) ? orderedSelection : [focused]
            return PhotoActionTargets(ids: ids, primaryID: focused, mode: mode)
        }
    }
}
