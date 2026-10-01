//
//  LibraryGridView.swift
//  sloproom
//
//  Thumbnail grid for the current source.
//  Mouse: click / ⌘-click / ⇧-click select, double-click opens Develop, drag photos onto a
//  sidebar folder (dragging a selected photo drags the whole selection).
//  Keys (registry actions via the shortcut dispatcher; defaults): grid focused — arrows move
//  (up/down by row), ⇧-arrows extend, Return opens Develop, ⌫ removes from the shown folder (or
//  from the catalog, confirmed); anywhere in Library — ⌘= / ⌘- (also ⌘+) step the thumbnail
//  size slider. ⌘A / D: LibraryKeyMonitor.swift; P / U / X / G are menu key equivalents.
//

import AppKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(LibraryGridView.cellSizeKey) private var cellSize: Double = 180
    @FocusState private var isGridFocused: Bool
    @State private var keys = GridKeyState()

    private let spacing: CGFloat = 6
    private let padding: CGFloat = 10

    var body: some View {
        Group {
            if model.photos.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    grid(columns: columnCount(width: geo.size.width))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { GridFilterBar() }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .shortcutHandlers { [model, keys] in Self.keyHandlers(model: model, keys: keys) }
        .confirmationDialog(removalTitle, isPresented: Binding(
            get: { keys.pendingCatalogRemoval != nil },
            set: { if !$0 { keys.pendingCatalogRemoval = nil } }
        ), presenting: keys.pendingCatalogRemoval) { ids in
            Button("Remove from Catalog", role: .destructive) { FolderActions.removeFromCatalog(ids, model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { ids in
            let copies = (try? model.catalog.cascadedVirtualCopyCount(removing: ids)) ?? 0
            Text(copies > 0 ? "Virtual copies are removed with their original. The files on disk are not deleted."
                            : "The files on disk are not deleted.")
        }
    }

    private func columnCount(width: CGFloat) -> Int {
        max(1, Int((width - padding * 2 + spacing) / (CGFloat(cellSize) + spacing)))
    }

    private func grid(columns: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(model.photos) { photo in
                        PhotoGridCell(photo: photo,
                                      isSelected: model.selection.contains(photo.id),
                                      isFocused: model.focusedPhotoID == photo.id,
                                      onTogglePick: { FlagActions.togglePick(photo, model: model) })
                            .id(photo.id)
                            .onTapGesture(count: 2) { model.openInDevelop(photo.id) }
                            .simultaneousGesture(TapGesture().onEnded {
                                let flags = NSEvent.modifierFlags
                                model.click(photoID: photo.id, command: flags.contains(.command), shift: flags.contains(.shift))
                                isGridFocused = true
                            })
                            .onDrag { PhotoDrag.provider(for: photo, model: model, selectUnselected: true) } preview: { PhotoDrag.preview(photo, model: model) }
                            .contextMenu { PhotoActionMenuItems(model: model, clicked: photo.id) }   // Actions/ registry
                    }
                }
                .padding(padding)
            }
            .photoDragOperations()
            .focusable()
            .focused($isGridFocused)
            .focusEffectDisabled()
            .onChange(of: isGridFocused, initial: true) { _, focused in keys.isGridFocused = focused }
            .onChange(of: columns, initial: true) { _, n in keys.columns = n }
            .onChange(of: model.focusedPhotoID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .onAppear {
                isGridFocused = true
                if let id = model.focusedPhotoID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Keys

    static let cellSizeKey = "library.cellSize"
    static let cellSizeRange: ClosedRange<Double> = 100...400
    static let cellSizeStep: Double = 20

    private static func keyHandlers(model: AppModel, keys: GridKeyState) -> [ShortcutHandler] {
        let focused: @MainActor (NSEvent) -> Bool = { _ in keys.isGridFocused }
        func move(_ action: ShortcutAction, _ delta: @escaping @MainActor () -> Int) -> ShortcutHandler {
            ShortcutHandler(action, when: focused) { event in
                let extend = event.modifierFlags.contains(.shift) && !(ShortcutStore.shared.binding(for: action)?.modifiers.contains(.shift) ?? false)
                moveFocus(by: delta(), extend: extend, model: model)
            }
        }
        return [
            move(.moveLeft) { -1 },
            move(.moveRight) { 1 },
            move(.moveUp) { -keys.columns },
            move(.moveDown) { keys.columns },
            ShortcutHandler(.openInDevelop, when: { _ in keys.isGridFocused && model.focusedPhotoID != nil }) { _ in
                if let id = model.focusedPhotoID { model.openInDevelop(id) }
            },
            ShortcutHandler(.removePhotos, when: { _ in keys.isGridFocused && !model.actionTargetIDs.isEmpty }) { _ in
                deleteKey(model: model, keys: keys)
            },
            ShortcutHandler(.thumbnailLarger) { _ in stepCellSize(up: true) },
            ShortcutHandler(.thumbnailSmaller) { _ in stepCellSize(up: false) },
        ]
    }

    /// ⌘= / ⌘-: one step of the size slider.
    static func stepCellSize(up: Bool) {
        let d = UserDefaults.standard
        let current = d.object(forKey: cellSizeKey) as? Double ?? 180
        let next = ((current / cellSizeStep).rounded() + (up ? 1 : -1)) * cellSizeStep
        d.set(min(max(next, cellSizeRange.lowerBound), cellSizeRange.upperBound), forKey: cellSizeKey)
    }

    /// Arrow keys; with ⇧ the selection extends from the anchor to the new focus.
    private static func moveFocus(by delta: Int, extend: Bool, model: AppModel) {
        guard extend, let current = model.focusedPhotoID, let i = model.index(of: current) else {
            model.moveFocus(by: delta)
            return
        }
        let next = min(max(i + delta, 0), model.photos.count - 1)
        model.click(photoID: model.photos[next].id, command: false, shift: true)
    }

    /// ⌫: non-destructive removal from the shown folder; elsewhere ask to remove from the catalog.
    private static func deleteKey(model: AppModel, keys: GridKeyState) {
        let ids = model.actionTargetIDs
        guard !ids.isEmpty else { return }
        if model.shownFolderID != nil {
            FolderActions.removeFromShownFolder(ids, model: model)
        } else {
            keys.pendingCatalogRemoval = ids
        }
    }

    private var removalTitle: String {
        VirtualCopyActions.removalTitle(keys.pendingCatalogRemoval ?? [], model: model)   // "… and its N virtual copies …"
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $cellSize, in: Self.cellSizeRange).frame(width: 140).controlSize(.small)
                .help(ShortcutStore.shared.help("Thumbnail Size", [.thumbnailSmaller, .thumbnailLarger]))
                .accessibilityLabel("Thumbnail Size")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(model.totalPhotoCount == 0 ? "Import photos to get started." : "No photos match the current source and filter.")
        } actions: {
            if model.totalPhotoCount == 0 {
                Button("Import Photos…") { model.presentedSheet = .importPhotos }
                    .help(ShortcutStore.shared.help("Import from a camera card or folder", .importPhotos))
                Button("Add Folder in Place (Dev)…") { DevTools.addFolderInPlace(model: model) }
                    .help("Add every photo of a folder without copying (developer tool)")
            }
        }
    }
}

/// State the grid's key handlers share with the view (focus, column count for ↑ / ↓, the
/// pending "remove from catalog" confirmation).
@Observable
final class GridKeyState {
    @ObservationIgnored var isGridFocused = false
    @ObservationIgnored var columns = 1
    var pendingCatalogRemoval: [Int64]?
}
