//
//  BulkCrop.swift
//  sloproom
//
//  Bulk Crop math (UI-free; Tools/actions_check.swift): one aspect ratio for many photos.
//  Each photo gets the LARGEST crop of that ratio that fits inside its current rotation /
//  straighten, centered — `CropMath.maxRect(aspect:)`, the same constraint math the crop tool
//  uses. Quarter turns, flip and straighten are kept; the previous crop rect is replaced.
//  "Match each photo" flips the ratio to the photo's orientation (a 4:5 preset gives portrait
//  photos 4:5 and landscape photos 5:4); "As written" uses it as is.
//  Afterwards each photo stays individually adjustable in Develop (preset + aspect lock set like
//  the crop tool's picker does).
//

import Foundation
import CoreGraphics

nonisolated struct BulkCropOptions: Equatable, Sendable {
    nonisolated enum Ratio: Equatable, Sendable {
        /// The photo's own frame ratio (after quarter turns): removes the crop but keeps the
        /// largest original-ratio rect inside the straightened image.
        case original
        /// width : height (a preset when `presetID` is set).
        case ratio(width: Double, height: Double, presetID: Int64?)
    }

    nonisolated enum Orientation: String, Equatable, Sendable, CaseIterable {
        /// Portrait photos get the portrait version of the ratio, landscape ones the landscape version.
        case matchPhoto
        /// The ratio exactly as written (9:16 is portrait for every photo).
        case asWritten
    }

    var ratio: Ratio
    var orientation: Orientation = .matchPhoto
}

nonisolated enum BulkCrop {
    /// Width / height of the crop for a frame of `frameSize`, or nil if the ratio is invalid.
    static func aspect(for options: BulkCropOptions, frameSize: CGSize) -> CGFloat? {
        guard frameSize.width > 0, frameSize.height > 0 else { return nil }
        switch options.ratio {
        case .original:
            return frameSize.width / frameSize.height
        case .ratio(let w, let h, _):
            guard w > 0, h > 0 else { return nil }
            var r = CGFloat(w / h)
            if options.orientation == .matchPhoto, abs(r - 1) > 1e-9, frameSize.width != frameSize.height {
                let photoIsPortrait = frameSize.height > frameSize.width
                let ratioIsPortrait = r < 1
                if photoIsPortrait != ratioIsPortrait { r = 1 / r }
            }
            return r
        }
    }

    /// `settings` with the bulk crop applied for a photo whose oriented (EXIF applied) size is
    /// `sourceSize`. nil when the photo's size is unknown (nothing to do).
    static func apply(_ options: BulkCropOptions, to settings: EditSettings, sourceSize: CGSize) -> EditSettings? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let math = CropMath(sourceSize: sourceSize, geometry: settings.geometry)
        guard let aspect = aspect(for: options, frameSize: math.frameSize) else { return nil }
        let rect = math.maxRect(aspect: aspect)   // centered, as large as fits the straightened content
        var out = settings
        out.geometry.crop = math.normRect(rect)
        switch options.ratio {
        case .original:
            out.geometry.cropPresetID = nil
            out.geometry.aspectLocked = true
            if out.geometry.straightenAngle == 0 { out.geometry.crop = .full }   // exactly the original
        case .ratio(_, _, let presetID):
            out.geometry.cropPresetID = presetID
            out.geometry.aspectLocked = true
        }
        return out
    }
}
