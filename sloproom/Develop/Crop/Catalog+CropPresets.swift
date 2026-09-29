//
//  Catalog+CropPresets.swift
//  sloproom
//
//  Crop preset API beyond the foundation's CRUD (Catalog+Roots.swift): default seeding and
//  reordering. The four base defaults (9:16, 1:1, 4:5, 3:2) are inserted by the foundation's
//  schema migration; the named migration below adds 16:9 once per catalog.
//

import Foundation

nonisolated extension Catalog {
    /// Makes sure the default presets exist. Runs each seed at most once per catalog (so presets
    /// the user deleted stay deleted). Cheap; call before listing presets.
    func ensureDefaultCropPresets() throws {
        try applyMigration(named: "crop.presets.16x9", sql: """
            INSERT INTO crop_presets(name, ratio_w, ratio_h, sort_order)
            SELECT 'Horizontal 16:9', 16, 9, COALESCE(MAX(sort_order) + 1, 0) FROM crop_presets;
            """)
    }

    /// Sets the sort order to the order of `ids` (0, 1, 2, …). Ids not listed keep their order
    /// after the listed ones.
    func reorderCropPresets(ids: [Int64]) throws {
        try db.transaction {
            let rest = try allCropPresets().map(\.id).filter { !ids.contains($0) }
            for (index, id) in (ids + rest).enumerated() {
                try db.run("UPDATE crop_presets SET sort_order = ? WHERE id = ?", [index, id])
            }
        }
        postChange(.cropPresets)
    }
}
