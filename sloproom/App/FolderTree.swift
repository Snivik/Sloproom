//
//  FolderTree.swift
//  sloproom
//
//  Builds a nested tree from the flat folder list (for OutlineGroup / List(children:)).
//

import Foundation

nonisolated struct FolderNode: Identifiable, Hashable, Sendable {
    let folder: Folder
    var children: [FolderNode]

    var id: Int64 { folder.id }
    /// nil for leaves, so OutlineGroup shows no disclosure triangle.
    var childrenOrNil: [FolderNode]? { children.isEmpty ? nil : children }
}

nonisolated enum FolderTree {
    /// Roots of the tree, siblings ordered by (sortOrder, name). Orphans (missing parent) become roots.
    static func build(_ folders: [Folder]) -> [FolderNode] {
        let ids = Set(folders.map(\.id))
        let byParent = Dictionary(grouping: folders) { f -> Int64? in
            guard let p = f.parentID, ids.contains(p) else { return nil }
            return p
        }
        func nodes(_ parent: Int64?) -> [FolderNode] {
            (byParent[parent] ?? [])
                .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
                .map { FolderNode(folder: $0, children: nodes($0.id)) }
        }
        return nodes(nil)
    }

    /// Ids of `id` and all descendants within `folders`.
    static func subtreeIDs(of id: Int64, in folders: [Folder]) -> Set<Int64> {
        let byParent = Dictionary(grouping: folders) { $0.parentID }
        var result: Set<Int64> = [id]
        var stack = [id]
        while let next = stack.popLast() {
            for child in byParent[next] ?? [] where result.insert(child.id).inserted {
                stack.append(child.id)
            }
        }
        return result
    }

    /// Path of folder names from the root to `id` (e.g. ["Trips", "Italy"]).
    static func path(to id: Int64, in folders: [Folder]) -> [Folder] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var result: [Folder] = []
        var cursor: Int64? = id
        while let c = cursor, let f = byID[c], !result.contains(where: { $0.id == c }) {
            result.insert(f, at: 0)
            cursor = f.parentID
        }
        return result
    }
}
