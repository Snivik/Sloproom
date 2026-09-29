//
//  shortcuts_check.swift
//  Tools
//
//  Headless check of the keyboard shortcut registry (sloproom/Shortcuts/ShortcutModel.swift +
//  ShortcutStore.swift): defaults, overrides persisting, conflicts per scope, narrower-scope
//  overrides, resolution order, reset / reset all, spec parsing and key formatting.
//
//    HARNESS_NO_DEFAULT=1 Tools/harness.sh /private/tmp/claude-501/<you>/shortcuts_check Tools/shortcuts_check.swift \
//      sloproom/Shortcuts/ShortcutModel.swift sloproom/Shortcuts/ShortcutStore.swift
//    /private/tmp/claude-501/<you>/shortcuts_check
//

import Foundation

@main
struct ShortcutsCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let suite = "sloproom.shortcuts_check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }

        print("Defaults")
        let store = ShortcutStore(defaults: defaults)
        let ids = ShortcutAction.allCases.map(\.id)
        check(Set(ids).count == ids.count, "\(ids.count) actions with unique ids")
        check(store.binding(for: .pick) == KeyCombo("p") && store.binding(for: .reject) == KeyCombo("x"), "P = Pick, X = Reject")
        check(store.binding(for: .exportPhotos) == KeyCombo("e", [.command, .shift]), "⇧⌘E = Export…")
        check(store.binding(for: .thumbnailLarger) == KeyCombo("=", .command) && store.binding(for: .thumbnailSmaller) == KeyCombo("-", .command),
              "⌘= / ⌘- = thumbnail size (Library)")
        check(store.binding(for: .zoomIn) == KeyCombo("=", .command), "⌘= = Zoom In (Develop & Full Screen)")
        check(store.binding(for: .exportCatalog) == nil && store.binding(for: .importCatalog) == nil, "Export / Import Catalog: no default")
        check(store.allConflicts.isEmpty, "no conflicts between the defaults (\(store.allConflicts.map { "\($0.0.id)/\($0.1.id)" }))")
        check(ShortcutAction.allCases.allSatisfy { !$0.title.isEmpty }, "every action has a display name")

        print("Formatting / parsing")
        check(KeyCombo("e", [.command, .shift]).display == "⇧⌘E", "⇧⌘E")
        check(KeyCombo("a", [.command, .option]).display == "⌥⌘A", "⌥⌘A")
        check(KeyCombo("x", [.control, .option, .shift, .command]).display == "⌃⌥⇧⌘X", "modifier order ⌃⌥⇧⌘")
        check(KeyCombo("=", .command).display == "⌘=" && KeyCombo("[", .command).display == "⌘[", "⌘= / ⌘[")
        check(KeyCombo("escape").display == "⎋" && KeyCombo("return").display == "↩" && KeyCombo("delete").display == "⌫"
              && KeyCombo("tab", .shift).display == "⇧⇥" && KeyCombo("space").display == "Space" && KeyCombo("left").display == "←",
              "special keys ⎋ ↩ ⌫ ⇧⇥ Space ←")
        check(KeyCombo(spec: "cmd+shift+e") == KeyCombo("e", [.command, .shift]), "parse cmd+shift+e")
        check(KeyCombo(spec: "k") == KeyCombo("k"), "parse k")
        check(KeyCombo(spec: "cmd+=") == KeyCombo("=", .command) && KeyCombo(spec: "cmd+plus") == KeyCombo("=", .command)
              && KeyCombo(spec: "cmd++") == KeyCombo("=", .command), "parse cmd+= / cmd+plus / cmd++")
        check(KeyCombo(spec: "shift+tab") == KeyCombo("tab", .shift) && KeyCombo(spec: "esc") == KeyCombo("escape"), "parse shift+tab / esc")
        check(KeyCombo(spec: "cmd+bogus") == nil && KeyCombo(spec: "hyper+k") == nil && KeyCombo(spec: "") == nil, "reject bad specs")
        for action in ShortcutAction.allCases {
            guard let combo = action.defaultBinding else { continue }
            if KeyCombo(spec: combo.spec) != combo { check(false, "spec round trip \(action.id) \(combo.spec)") }
        }
        check(true, "spec round trip of every default")

        print("Matching")
        let cmdEq = KeyCombo("=", .command)
        check(cmdEq.accepts(KeyCombo("=", [.command, .shift])), "⌘= also fires on ⌘+ (⌘⇧=)")
        check(cmdEq.accepts(KeyCombo("+", .command)), "⌘= also fires on keypad ⌘+")
        check(KeyCombo("-", .command).accepts(KeyCombo("-", [.command, .shift])), "⌘- also fires on ⌘_")
        check(!KeyCombo("p").accepts(KeyCombo("p", .shift)), "P does not fire on ⇧P")
        check(KeyCombo("left").accepts(KeyCombo("left", .shift), extraShift: true), "grid ← accepts ⇧← (extend selection)")
        check(KeyCombo("delete").accepts(KeyCombo("forwarddelete")), "⌫ also accepts ⌦")

        print("Scopes")
        check(!ShortcutScope.library.overlaps(.viewer), "Library and Develop & Full Screen don't overlap (⌘= means two things)")
        check(ShortcutScope.crop.isNarrower(than: .global) && !ShortcutScope.crop.conflicts(with: .global), "Crop overrides Everywhere (no conflict)")
        check(ShortcutScope.global.conflicts(with: .global), "Everywhere vs Everywhere conflicts")
        check(ShortcutScope.viewer.conflicts(with: .mainWindow), "partially overlapping scopes conflict")
        check(store.candidates(for: KeyCombo("x"), in: .crop) == [.cropSwapAspect, .reject], "X in the crop tool: Swap Aspect first, then Reject")
        check(store.candidates(for: KeyCombo("x"), in: .develop) == [.reject], "X in Develop: Reject")
        check(store.candidates(for: KeyCombo("=", .command), in: .library) == [.thumbnailLarger], "⌘= in Library: thumbnails")
        check(store.candidates(for: KeyCombo("=", [.command, .shift]), in: .develop) == [.zoomIn], "⌘+ in Develop: zoom in")
        check(store.candidates(for: KeyCombo("=", .command), in: .fullScreen) == [.zoomIn], "⌘= in full screen: zoom in")
        check(store.candidates(for: KeyCombo("delete"), in: .library) == [.removePhotos, .deleteFolder], "⌫ in Library: grid first, then sidebar")
        check(store.candidates(for: KeyCombo("escape"), in: .mask) == [.maskCancel], "Esc in the mask tool")
        check(store.overridden(by: .cropSwapAspect) == [.reject], "Swap Aspect overrides Reject in the crop tool")

        print("Overrides / conflicts")
        store.setBinding(KeyCombo("k"), for: .pick)
        check(store.binding(for: .pick) == KeyCombo("k") && store.isCustomized(.pick), "rebind Pick to K")
        check(store.candidates(for: KeyCombo("p"), in: .library).isEmpty, "P does nothing any more")
        check(store.help("Pick", .pick) == "Pick (K)", "tooltip follows: \(store.help("Pick", .pick))")
        let reloaded = ShortcutStore(defaults: defaults)
        check(reloaded.binding(for: .pick) == KeyCombo("k"), "override persists (new store, same defaults)")
        check(store.conflicts(for: KeyCombo("k"), action: .reject) == [.pick], "K for Reject conflicts with Pick (both Everywhere)")
        check(store.conflicts(for: KeyCombo("k"), action: .cropGridOverlay).isEmpty, "K for Cycle Grid Overlay: crop overrides, no conflict")
        check(store.conflicts(for: KeyCombo("=", .command), action: .zoomIn) == [], "⌘= for Zoom In: no conflict with thumbnails")
        check(store.conflicts(for: KeyCombo("r"), action: .maskOverlay).isEmpty, "R in the mask tool overrides Crop Tool (Develop)")
        check(store.conflicts(for: KeyCombo("tab"), action: .fullScreenPreview).isEmpty, "Tab for Full Screen (everywhere) is overridden by Tab in Develop, no conflict")
        check(store.conflicts(for: KeyCombo("left"), action: .selectAllPhotos) == [.previousPhoto],
              "← for Select All Photos (Library & Develop) conflicts with Previous Photo (Develop & Full Screen): partial overlap")
        check(store.conflicts(for: KeyCombo("left"), action: .toggleCropTool).isEmpty, "← for Crop Tool (Develop) overrides Previous Photo there")
        store.reassign(KeyCombo("k"), to: .reject)
        check(store.binding(for: .reject) == KeyCombo("k") && store.binding(for: .pick) == nil, "Reassign: Reject = K, Pick has none")
        check(store.allConflicts.isEmpty, "no conflicts after reassigning")
        store.setBinding(KeyCombo("p"), for: .pick)
        check(!store.isCustomized(.pick), "setting the default back removes the override")
        store.reset(.reject)
        check(store.binding(for: .reject) == KeyCombo("x") && !store.isCustomized(.reject), "Reset Reject to default")
        store.setBinding(nil, for: .exportPhotos)
        store.setBinding(KeyCombo("f5"), for: .exportCatalog)
        check(store.binding(for: .exportPhotos) == nil && store.display(.exportPhotos).isEmpty && store.help("Export…", .exportPhotos) == "Export…",
              "remove a shortcut (tooltip without key)")
        check(ShortcutStore(defaults: defaults).binding(for: .exportPhotos) == nil, "a removed shortcut persists as 'none'")
        store.resetAll()
        check(store.overrides.isEmpty && store.binding(for: .exportPhotos) == KeyCombo("e", [.command, .shift]) && store.binding(for: .exportCatalog) == nil,
              "Reset All")
        check(ShortcutStore(defaults: defaults).overrides.isEmpty, "Reset All persists")

        print(failures == 0 ? "ALL SHORTCUT CHECKS PASSED" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
