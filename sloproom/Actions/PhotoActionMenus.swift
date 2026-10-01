//
//  PhotoActionMenus.swift
//  sloproom
//
//  Every photo-action surface, built from the registry (PhotoActionSpec.all, in group order,
//  a divider between groups):
//  - `PhotoActionMenuItems(model:clicked:)`: grid and filmstrip context menus (Library AND
//    Develop) and the Develop toolbar's actions menu. Titles follow the number of targets ("Pick
//    12 Photos"); actions whose arity doesn't fit are shown DISABLED with a tooltip ("Select a
//    single photo"), never hidden.
//  - `PhotoMenuBarItems`: the menu bar's Photo menu. Static titles (ShortcutMenuSync patches key
//    equivalents by title) and the user's shortcuts (ShortcutMenuButton for menu commands);
//    enablement from the target count focused value (Commands aren't re-rendered on selection
//    changes); targets are resolved when an item is chosen.
//  - `PhotoActionsToolbarMenu`: "…" in the main window toolbar while in Develop.
//

import AppKit
import SwiftUI

/// Context-menu / actions-menu content for the current targets.
struct PhotoActionMenuItems: View {
    let model: AppModel
    /// The cell the context menu was opened on (nil: the Develop toolbar menu).
    var clicked: Int64?

    var body: some View {
        let targets = PhotoActions.targets(model: model, clicked: clicked)
        let entries = PhotoActionMenuItems.entries(targets, model: model)
        let groups = PhotoActionGroup.allCases.filter { g in entries.contains { $0.spec.group == g } }
        ForEach(groups, id: \.self) { group in
            if group != groups.first { Divider() }
            ForEach(entries.filter { $0.spec.group == group }) { entry in
                PhotoActionMenuItem(spec: entry.spec, availability: entry.availability, targets: targets, model: model)
            }
        }
    }

    struct Entry: Identifiable {
        let spec: PhotoActionSpec
        let availability: PhotoActionAvailability
        var id: PhotoActionID { spec.id }
    }

    /// The visible actions for `targets`, in menu order (also printed by DevScript `act menu`).
    static func entries(_ targets: PhotoActionTargets, model: AppModel) -> [Entry] {
        PhotoActionSpec.all.compactMap { spec in
            let a = PhotoActions.availability(spec, targets, model: model)
            return a == .hidden ? nil : Entry(spec: spec, availability: a)
        }
    }
}

private struct PhotoActionMenuItem: View {
    let spec: PhotoActionSpec
    let availability: PhotoActionAvailability
    let targets: PhotoActionTargets
    let model: AppModel

    var body: some View {
        let title = spec.title(count: targets.count)
        let tip = PhotoActions.tooltip(spec, availability)
        if spec.isFolderMenu {
            Menu(title) {
                FolderMenuTree(nodes: model.folderTree, disabledID: spec.id == .moveToFolder ? model.shownFolderID : nil) { folderID in
                    PhotoActions.performFolder(spec.id, targets, folderID: folderID, model: model)
                }
            }
            .disabled(!availability.isEnabled)
            .help(tip)
        } else {
            Button(title) { PhotoActions.perform(spec.id, targets, model: model) }
                .disabled(!availability.isEnabled)
                .help(tip)
        }
    }
}

/// The Photo menu of the menu bar (`SloproomCommands`). `targetCount` = number of action
/// targets of the focused main window (nil = unknown: everything enabled, checked when chosen).
struct PhotoMenuBarItems: View {
    let model: AppModel
    let targetCount: Int?

    var body: some View {
        // Flags, then the existing extras, as before.
        items(.flags)
        AutoAdvanceToggle()
        Divider()
        Menu("Set Rating") {
            ForEach(0...5, id: \.self) { stars in
                ShortcutMenuButton(.rating(stars), title: stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    model.setRating(stars)
                }
            }
        }
        Divider()
        items(.edits)
        ShortcutMenuButton(.beforeAfter) { model.developSession?.showBefore.toggle() }
        Divider()
        items(.virtualCopies)
        Divider()
        items(.open)
        Divider()
        items(.folders)
        Divider()
        items(.removal)
    }

    @ViewBuilder private func items(_ group: PhotoActionGroup) -> some View {
        ForEach(PhotoActionSpec.all.filter { $0.group == group && $0.inMenuBar }) { spec in
            item(spec)
        }
    }

    @ViewBuilder private func item(_ spec: PhotoActionSpec) -> some View {
        let enabled = targetCount.map { spec.arity.accepts($0) } ?? true
        let perform = { PhotoActions.performFromMenu(spec.id, model: model) }
        if let shortcut = spec.shortcut, shortcut.isMenuCommand {
            ShortcutMenuButton(shortcut, title: spec.menuTitle, perform: perform)
                .disabled(!enabled)
                .help(enabled ? ShortcutStore.shared.help(spec.help, shortcut) : spec.arity.disabledReason(targetCount ?? 0) ?? spec.help)
        } else {
            Button(spec.menuTitle, action: perform)
                .disabled(!enabled)
                .help(enabled ? spec.help : spec.arity.disabledReason(targetCount ?? 0) ?? spec.help)
        }
    }
}

/// Develop: "…" toolbar menu with every action for the current targets (Develop has no grid,
/// and it is the only way to see photos full size).
struct PhotoActionsToolbarMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            PhotoActionMenuItems(model: model)
        } label: {
            Label("Photo Actions", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help(Self.help(model))
        .accessibilityLabel("Photo Actions")
        .onAppear { ToolbarMenuTooltips.install(model: model) }
    }

    static func help(_ model: AppModel) -> String {
        let n = PhotoActions.targets(model: model).count
        return n > 1 ? "Actions for the \(n) photos selected in the filmstrip" : "Actions for this photo (select several in the filmstrip to act on all of them)"
    }
}

/// SwiftUI doesn't pass `.help` of the items of a TOOLBAR menu to their NSMenuItems (context
/// menus get them): when that menu opens, its items get the registry tooltips by title
/// ("Select a single photo" on disabled single-photo actions, help + shortcut otherwise).
enum ToolbarMenuTooltips {
    private static var observer: NSObjectProtocol?
    private static weak var menu: NSMenu?
    private static weak var model: AppModel?

    static func install(model: AppModel) {
        self.model = model
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, menu.supermenu !== NSApp.mainMenu else { return }
                self.menu = menu
                apply()
                // SwiftUI may fill the menu just after tracking begins: once more from the tracking loop.
                RunLoop.main.add(Timer(timeInterval: 0.05, repeats: false) { _ in MainActor.assumeIsolated { apply() } }, forMode: .common)
            }
        }
    }

    private static func apply() {
        guard let model, let menu, model.mode == .develop else { return }
        let targets = PhotoActions.targets(model: model)
        var tips: [String: String] = [:]
        for e in PhotoActionMenuItems.entries(targets, model: model) {
            tips[e.spec.title(count: targets.count)] = PhotoActions.tooltip(e.spec, e.availability)
        }
        // Only a menu made of our items (the toolbar menu), and only items without a tooltip.
        let titled = menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }
        guard !titled.isEmpty, titled.allSatisfy({ tips[$0.title] != nil }) else { return }
        for item in titled where item.toolTip == nil { item.toolTip = tips[item.title] }
    }
}
