//
//  FolderMenuTree.swift
//  sloproom
//
//  Nested folder submenus ("Add to Folder ▸", "Move to Folder ▸"). A folder with subfolders
//  becomes a submenu whose first item is the folder itself.
//

import SwiftUI

struct FolderMenuTree: View {
    let nodes: [FolderNode]
    var disabledID: Int64?
    let action: (Int64) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                item(node)
            } else {
                Menu(node.folder.name) {
                    item(node)
                    Divider()
                    FolderMenuTree(nodes: node.children, disabledID: disabledID, action: action)
                }
            }
        }
    }

    private func item(_ node: FolderNode) -> some View {
        Button(node.folder.name) { action(node.id) }
            .disabled(node.id == disabledID)
    }
}
