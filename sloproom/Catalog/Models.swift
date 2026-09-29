//
//  Models.swift
//  sloproom
//
//  Plain value types mirroring catalog rows. All are nonisolated + Sendable so they
//  can be produced/consumed on any thread.
//

import Foundation
import CoreGraphics

/// Pick / Unflag / Reject. Raw values are what is stored in `photos.flag`.
nonisolated enum Flag: Int, Codable, Sendable, Hashable, CaseIterable {
    case reject = -1
    case none = 0
    case pick = 1
}

nonisolated struct Photo: Identifiable, Hashable, Sendable {
    /// Catalog row id. `0` for a photo that has not been inserted yet.
    var id: Int64 = 0
    /// Absolute POSIX path of the original file (unique in catalog).
    var path: String
    /// Covering root (security-scoped bookmark), if any. Filled automatically on insert.
    var rootID: Int64? = nil
    var fileName: String
    var fileSize: Int64 = 0
    var captureDate: Date? = nil
    var importDate: Date = Date()
    /// Pixel dimensions as stored in the file (NOT orientation-corrected).
    var width: Int = 0
    var height: Int = 0
    /// EXIF orientation 1...8 (1 = up).
    var orientation: Int = 1
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var lens: String? = nil
    var iso: Int? = nil
    /// Exposure time in seconds.
    var shutter: Double? = nil
    /// f-number.
    var aperture: Double? = nil
    /// Focal length in mm.
    var focalLength: Double? = nil
    var flag: Flag = .none
    /// 0...5 stars.
    var rating: Int = 0
    /// Raw JSON of `EditSettings`, nil = never edited. Use `editSettings` to decode.
    var editSettingsJSON: String? = nil
    /// Incremented on every `Catalog.saveEditSettings`. Previews key off (id, editVersion).
    var editVersion: Int = 0
    /// Paired file (e.g. the camera JPG next to a DNG).
    var sidecarPath: String? = nil
    /// Lightroom Classic `Adobe_images.id_local` when imported from an LrC catalog.
    var lrImageID: Int64? = nil

    init(path: String, fileName: String? = nil) {
        self.path = path
        self.fileName = fileName ?? (path as NSString).lastPathComponent
    }

    var url: URL { URL(fileURLWithPath: path) }
    var sidecarURL: URL? { sidecarPath.map { URL(fileURLWithPath: $0) } }

    /// Size after applying EXIF orientation (orientations 5...8 swap width/height).
    var orientedSize: CGSize {
        orientation >= 5 && orientation <= 8
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Decoded edit settings (defaults when never edited or undecodable).
    var editSettings: EditSettings { EditSettings.fromJSON(editSettingsJSON) ?? EditSettings() }
    var hasEdits: Bool { editSettingsJSON != nil && !editSettings.isDefault }
}

/// A virtual folder (collection). Arbitrarily nested; `parentID == nil` means top level.
nonisolated struct Folder: Identifiable, Hashable, Sendable {
    var id: Int64
    var parentID: Int64?
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var lrCollectionID: Int64? = nil
}

/// A disk folder / volume the user granted access to via a security-scoped bookmark.
nonisolated struct Root: Identifiable, Hashable, Sendable {
    var id: Int64
    /// Absolute POSIX path without trailing slash.
    var path: String
    var bookmark: Data?
    var displayName: String?
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// A crop aspect ratio preset. "Original" is built into the UI and never stored.
nonisolated struct CropPreset: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var ratioW: Double
    var ratioH: Double
    var sortOrder: Int
    /// width / height
    var ratio: Double { ratioH == 0 ? 1 : ratioW / ratioH }
}

// MARK: - Query descriptors

/// Where photos come from.
nonisolated enum PhotoSource: Hashable, Sendable {
    case all
    /// Photos directly in the folder, or also in all descendant folders (deduplicated).
    case folder(id: Int64, includeSubfolders: Bool)
    /// Photos whose `import_date` equals the newest `import_date` in the catalog.
    /// Importers: use ONE `importDate` value for every photo of an import session.
    case lastImport
}

nonisolated enum FlagFilter: String, Hashable, Sendable, CaseIterable {
    case all, picked, rejected, unflagged, notRejected

    var title: String {
        switch self {
        case .all: "All"
        case .picked: "Picked"
        case .rejected: "Rejected"
        case .unflagged: "Unflagged"
        case .notRejected: "Not Rejected"
        }
    }
}

/// Filter applied on top of a source. A struct so more criteria can be added later
/// (add a field with a default + handle it in `Catalog.photos(in:filter:sort:)`).
nonisolated struct PhotoFilter: Hashable, Sendable {
    var flag: FlagFilter = .all
    /// Minimum star rating (0 = no constraint).
    var minRating: Int = 0
}

nonisolated struct PhotoSort: Hashable, Sendable {
    nonisolated enum Key: String, Hashable, Sendable, CaseIterable {
        /// Capture date (NULLs last), then file name.
        case captureDate
        case importDate
        case fileName
        /// Manual order inside a folder (`folder_photos.sort_order`); falls back to capture date for `.all`.
        case folderOrder
    }
    var key: Key = .captureDate
    var ascending: Bool = true
}
