//
//  FolderRowView.swift
//  sloproom
//
//  The nested folder outline: DisclosureGroups with persisted expansion (OutlineGroup can't
//  bind expansion), rows with inline rename, counts, drag source and drop target.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FolderOutline: View {
    let nodes: [FolderNode]
    let counts: SidebarCounts

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                FolderRowView(node: node, counts: counts)
                    .tag(SidebarItem.folder(node.id))
            } else {
                DisclosureGroup(isExpanded: FolderSidebarState.shared.expansionBinding(node.id)) {
                    FolderOutline(nodes: node.children, counts: counts)
                } label: {
                    FolderRowView(node: node, counts: counts)
                        .tag(SidebarItem.folder(node.id))
                }
            }
        }
    }
}

struct FolderRowView: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let counts: SidebarCounts

    @State private var draftName = ""
    @FocusState private var isFieldFocused: Bool
    @State private var dropZone: FolderDropZone?
    @State private var rowHeight: CGFloat = 22

    private var state: FolderSidebarState { .shared }
    private var isRenaming: Bool { state.renamingFolderID == node.id }
    private var directCount: Int { model.folderCounts[node.id] ?? 0 }
    private var totalCount: Int { counts.folderTotals[node.id] ?? directCount }

    var body: some View {
        Label {
            if isRenaming { renameField } else { Text(node.folder.name).lineLimit(1) }
        } icon: {
            Image(systemName: node.children.isEmpty ? "folder" : "folder.fill")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(tooltip)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
        .modifier(FolderDragSource(folderID: node.id, isEnabled: !isRenaming))
        .onDrop(of: [.plainText], delegate: FolderRowDropDelegate(folderID: node.id, rowHeight: rowHeight, model: model, zone: $dropZone))
        .background {
            if dropZone == .into {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2)
            }
        }
        .overlay(alignment: dropZone == .after ? .bottom : .top) {
            if dropZone == .before || dropZone == .after {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: dropZone == .after ? 2 : -2)
            }
        }
        .badge(model.includeSubfolders && !node.children.isEmpty ? totalCount : directCount)
    }

    private var renameField: some View {
        TextField("Folder Name", text: $draftName)
            .textFieldStyle(.plain)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1))
            .focused($isFieldFocused)
            .onSubmit(commitRename)
            .onExitCommand { state.renamingFolderID = nil }
            .onAppear {
                draftName = node.folder.name
                // Focus once the field is in the window (focusing in the same pass is ignored).
                DispatchQueue.main.async { isFieldFocused = true }
            }
            .onChange(of: isFieldFocused) { wasFocused, focused in
                if wasFocused && !focused && isRenaming { commitRename() }   // click elsewhere commits
            }
    }

    private func commitRename() {
        guard isRenaming else { return }
        state.renamingFolderID = nil
        FolderActions.rename(node.id, to: draftName, model: model)
    }

    private var tooltip: String {
        func photos(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
        if node.children.isEmpty { return "\(node.folder.name): \(photos(directCount))" }
        return "\(node.folder.name): \(photos(directCount)) directly, \(photos(totalCount)) including subfolders"
    }
}

/// Makes a row draggable, except while its name is being edited (mouse-drag selects text then).
/// Uses `itemProvider` (the List-row drag API): `onDrag` on a List row swallows the mouse-down,
/// so clicking the row's name wouldn't select the folder.
private struct FolderDragSource: ViewModifier {
    let folderID: Int64
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.itemProvider(isEnabled ? { SloproomDrag.provider(.folder(folderID)) } : nil)
    }
}

/// "Folders" section header: new-folder button, and drop target for moving a folder to the top level.
struct FoldersSectionHeader: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Text("Folders")
            Spacer()
            Button {
                FolderActions.newFolder(parentID: nil, model: model)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .iconHelp("New Folder", shortcut: .newFolder)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background {
            if isTargeted { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.25)).padding(-3) }
        }
        .onDrop(of: [.plainText], delegate: TopLevelFolderDropDelegate(model: model, isTargeted: $isTargeted))
        .help(isTargeted ? "Drop to move to the top level" : "")
    }
}
