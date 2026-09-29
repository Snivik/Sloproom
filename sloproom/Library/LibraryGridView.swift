//
//  LibraryGridView.swift
//  sloproom
//
//  Thumbnail grid for the current source.
//  Mouse: click / ⌘-click / ⇧-click select, double-click opens Develop, drag photos onto a
//  sidebar folder (dragging a selected photo drags the whole selection).
//  Keys (grid focused): arrows move (up/down by row), ⇧-arrows extend, Return opens Develop, ⌫ removes from the shown folder (or from the catalog, confirmed).
//  ⌘A / D: LibraryKeyMonitor.swift; P / U / X / G are menu key equivalents (FlagActions.swift).
//

import AppKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("library.cellSize") private var cellSize: Double = 180
    @FocusState private var isGridFocused: Bool
    @State private var pendingCatalogRemoval: [Int64]?

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
        .confirmationDialog(removalTitle, isPresented: Binding(
            get: { pendingCatalogRemoval != nil },
            set: { if !$0 { pendingCatalogRemoval = nil } }
        ), presenting: pendingCatalogRemoval) { ids in
            Button("Remove from Catalog", role: .destructive) { FolderActions.removeFromCatalog(ids, model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The files on disk are not deleted.")
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
                            .onDrag { SloproomDrag.provider(.photos(dragIDs(for: photo))) } preview: { dragPreview(photo) }
                            .contextMenu { cellMenu(photo) }
                    }
                }
                .padding(padding)
            }
            .focusable()
            .focused($isGridFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let delta = switch press.key {
                case .leftArrow: -1
                case .rightArrow: 1
                case .upArrow: -columns
                default: columns
                }
                moveFocus(by: delta, extend: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                guard let id = model.focusedPhotoID else { return .ignored }
                model.openInDevelop(id)
                return .handled
            }
            .onDeleteCommand { deleteKey() }
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

    /// Arrow keys; with ⇧ the selection extends from the anchor to the new focus.
    private func moveFocus(by delta: Int, extend: Bool) {
        guard extend, let current = model.focusedPhotoID, let i = model.index(of: current) else {
            model.moveFocus(by: delta)
            return
        }
        let next = min(max(i + delta, 0), model.photos.count - 1)
        model.click(photoID: model.photos[next].id, command: false, shift: true)
    }

    /// ⌫: non-destructive removal from the shown folder; elsewhere ask to remove from the catalog.
    private func deleteKey() {
        let ids = model.actionTargetIDs
        guard !ids.isEmpty else { return }
        if model.shownFolderID != nil {
            FolderActions.removeFromShownFolder(ids, model: model)
        } else {
            pendingCatalogRemoval = ids
        }
    }

    /// Dragging a selected photo drags the whole selection (in grid order); dragging an
    /// unselected photo selects it first.
    private func dragIDs(for photo: Photo) -> [Int64] {
        if model.selection.contains(photo.id) { return model.actionTargetIDs }
        model.click(photoID: photo.id, command: false, shift: false)
        return [photo.id]
    }

    /// Small thumbnail with the number of dragged photos.
    private func dragPreview(_ photo: Photo) -> some View {
        let count = model.selection.contains(photo.id) ? model.selection.count : 1
        return ZStack(alignment: .topTrailing) {
            if let image = PreviewService.shared.cachedImage(for: photo, level: .thumbnail) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            if count > 1 {
                Text(count.formatted())
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: 96, height: 96)
    }

    /// Context-menu targets: the selection if the clicked photo is part of it, else that photo.
    private func targets(_ photo: Photo) -> [Int64] {
        model.selection.contains(photo.id) ? model.actionTargetIDs : [photo.id]
    }

    @ViewBuilder
    private func cellMenu(_ photo: Photo) -> some View {
        let ids = targets(photo)
        let shown = model.shownFolderID
        Button("Open in Develop") { model.openInDevelop(photo.id) }
        Divider()
        Button("Pick") { flag(photo, .pick) }
        Button("Unflag") { flag(photo, .none) }
        Button("Reject") { flag(photo, .reject) }
        Divider()
        if !model.folderTree.isEmpty {
            Menu("Add to Folder") {
                FolderMenuTree(nodes: model.folderTree) { FolderActions.addPhotos(ids, to: $0, move: false, model: model) }
            }
            if shown != nil {
                Menu("Move to Folder") {
                    FolderMenuTree(nodes: model.folderTree, disabledID: shown) { FolderActions.addPhotos(ids, to: $0, move: true, model: model) }
                }
            }
        }
        Button("New Folder with \(ids.count == 1 ? "Photo" : "\(ids.count) Photos")") {
            FolderActions.newFolder(parentID: nil, photoIDs: ids, model: model)
        }
        if shown != nil {
            Button("Remove from This Folder") { FolderActions.removeFromShownFolder(ids, model: model) }
        }
        Divider()
        ExportMenuButton(ids: ids, model: model)
        Divider()
        Button("Remove from Catalog…") { pendingCatalogRemoval = ids }
    }

    private func flag(_ photo: Photo, _ flag: Flag) {
        if !model.selection.contains(photo.id) { model.click(photoID: photo.id, command: false, shift: false) }
        model.setFlag(flag)
    }

    private var removalTitle: String {
        let n = pendingCatalogRemoval?.count ?? 0
        return n == 1 ? "Remove this photo from the catalog?" : "Remove \(n) photos from the catalog?"
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
            Slider(value: $cellSize, in: 100...400).frame(width: 140).controlSize(.small)
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
                Button("Add Folder in Place (Dev)…") { DevTools.addFolderInPlace(model: model) }
            }
        }
    }
}
