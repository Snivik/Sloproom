//
//  Catalog+Import.swift
//  sloproom
//
//  Catalog queries used by the SD card / folder importer.
//

import Foundation

nonisolated struct ImportFingerprint: Sendable, Hashable {
    var path: String
    var fileName: String
    var fileSize: Int64
    var captureDate: Date?
}

nonisolated extension Catalog {
    /// Path, file name, size and capture date of every photo (for duplicate detection). Masters
    /// only: virtual copies share their master's file.
    func importFingerprints() throws -> [ImportFingerprint] {
        try db.query("SELECT path, file_name, file_size, capture_date FROM photos WHERE master_id IS NULL", []) {
            ImportFingerprint(path: $0.string(0), fileName: $0.string(1), fileSize: $0.int(2), captureDate: $0.date(3))
        }
    }
}
