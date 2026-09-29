//
//  Catalog+Previews.swift
//  sloproom
//

import Foundation

nonisolated extension Catalog {
    /// Every photo id, newest capture first (order for "Build for All").
    func allPhotoIDs() throws -> [Int64] {
        try db.query("SELECT id FROM photos ORDER BY capture_date IS NULL, capture_date DESC, id DESC") { $0.int(0) }
    }
}
