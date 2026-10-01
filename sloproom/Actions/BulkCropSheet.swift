//
//  BulkCropSheet.swift
//  sloproom
//
//  Bulk Crop… sheet: aspect (the catalog's crop presets — user-editable in Develop's crop panel —,
//  Original, or a custom W:H), orientation ("Match each photo": portrait photos get the portrait
//  version of the ratio, landscape ones the landscape version; or "As written"), and a live
//  preview of the first six targets with the new crop. Centered, largest crop that fits each
//  photo's current rotation / straighten (`BulkCrop`, CropMath). Replaces existing crops; one
//  undo step. The choice is remembered.
//

import SwiftUI

/// The sheet's choices (shared so DevScript can drive the real sheet).
@Observable
final class BulkCropChoice {
    static let shared = BulkCropChoice()

    enum Aspect: Hashable {
        case original
        case preset(Int64)
        case custom
    }

    var aspect: Aspect = .preset(1)
    var customWidth: Double = 4
    var customHeight: Double = 5
    var orientation: BulkCropOptions.Orientation = .matchPhoto
    var presets: [CropPreset] = []

    private let defaults = UserDefaults.standard

    init() {
        switch defaults.string(forKey: "actions.bulkCrop.aspect") ?? "" {
        case "original": aspect = .original
        case "custom": aspect = .custom
        case let s where s.hasPrefix("preset:"): aspect = Int64(s.dropFirst(7)).map { .preset($0) } ?? .preset(1)
        default: break
        }
        if let w = defaults.object(forKey: "actions.bulkCrop.customW") as? Double, w > 0 { customWidth = w }
        if let h = defaults.object(forKey: "actions.bulkCrop.customH") as? Double, h > 0 { customHeight = h }
        orientation = BulkCropOptions.Orientation(rawValue: defaults.string(forKey: "actions.bulkCrop.orientation") ?? "") ?? .matchPhoto
    }

    func save() {
        let a: String
        switch aspect {
        case .original: a = "original"
        case .custom: a = "custom"
        case .preset(let id): a = "preset:\(id)"
        }
        defaults.set(a, forKey: "actions.bulkCrop.aspect")
        defaults.set(customWidth, forKey: "actions.bulkCrop.customW")
        defaults.set(customHeight, forKey: "actions.bulkCrop.customH")
        defaults.set(orientation.rawValue, forKey: "actions.bulkCrop.orientation")
    }

    func loadPresets(_ catalog: Catalog) {
        try? catalog.ensureDefaultCropPresets()
        presets = (try? catalog.allCropPresets()) ?? []
        if case .preset(let id) = aspect, !presets.contains(where: { $0.id == id }) {
            aspect = presets.first.map { .preset($0.id) } ?? .original
        }
    }

    /// nil when the custom ratio is invalid.
    var options: BulkCropOptions? {
        switch aspect {
        case .original:
            return BulkCropOptions(ratio: .original, orientation: orientation)
        case .preset(let id):
            guard let p = presets.first(where: { $0.id == id }), p.ratioW > 0, p.ratioH > 0 else { return nil }
            return BulkCropOptions(ratio: .ratio(width: p.ratioW, height: p.ratioH, presetID: id), orientation: orientation)
        case .custom:
            guard customWidth > 0, customHeight > 0 else { return nil }
            return BulkCropOptions(ratio: .ratio(width: customWidth, height: customHeight, presetID: nil), orientation: orientation)
        }
    }

    var aspectTitle: String {
        switch aspect {
        case .original: "Original"
        case .custom: "\(Self.number(customWidth)):\(Self.number(customHeight))"
        case .preset(let id): presets.first { $0.id == id }.map { "\($0.name) (\(Self.number($0.ratioW)):\(Self.number($0.ratioH)))" } ?? "Preset"
        }
    }

    static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v) }
}

struct BulkCropSheet: View {
    let model: AppModel
    let ids: [Int64]
    @Bindable private var choice = BulkCropChoice.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bulk Crop \(PhotoActionSpec.photos(ids.count))").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Aspect:").gridColumnAlignment(.trailing)
                    HStack {
                        Picker("Aspect", selection: $choice.aspect) {
                            Text("Original").tag(BulkCropChoice.Aspect.original)
                            Divider()
                            ForEach(choice.presets) { p in
                                Text("\(p.name)  \(BulkCropChoice.number(p.ratioW)):\(BulkCropChoice.number(p.ratioH))")
                                    .tag(BulkCropChoice.Aspect.preset(p.id))
                            }
                            Divider()
                            Text("Custom…").tag(BulkCropChoice.Aspect.custom)
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        .help("Crop presets are edited in Develop's Crop panel (Edit Presets…)")
                        if choice.aspect == .custom {
                            TextField("W", value: $choice.customWidth, format: .number)
                                .frame(width: 44).help("Custom ratio: width")
                            Text(":")
                            TextField("H", value: $choice.customHeight, format: .number)
                                .frame(width: 44).help("Custom ratio: height")
                        }
                    }
                }
                GridRow {
                    Text("Orientation:")
                    Picker("Orientation", selection: $choice.orientation) {
                        Text("Match each photo").tag(BulkCropOptions.Orientation.matchPhoto)
                        Text("As written").tag(BulkCropOptions.Orientation.asWritten)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .segmentHelp(["Portrait photos get the portrait version of the ratio, landscape photos the landscape version (4:5 → 5:4)",
                                  "Use the ratio exactly as written for every photo (9:16 is portrait everywhere)"])
                    .disabled(choice.aspect == .original)
                }
            }
            BulkCropPreviewGrid(model: model, ids: Array(ids.prefix(6)), options: choice.options)
            Label("Replaces the existing crops. Rotation and straighten are kept; the crop is centered and as large as fits. "
                  + "Each photo stays adjustable in Develop, and Edit > Undo reverts all of them.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without changing any photo")
                Button("Crop \(PhotoActionSpec.photos(ids.count))") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice.options == nil)
                    .help("Apply \(choice.aspectTitle) to every photo (one undo step)")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { choice.loadPresets(model.catalog) }
    }

    private func apply() {
        guard let options = choice.options else { return }
        choice.save()
        PhotoActions.bulkCrop(ids, options: options, model: model)
        dismiss()
    }
}

/// The first targets with their new crop: the frame (after rotation) with the area outside the
/// crop dimmed. Uses the grid thumbnail when the photo isn't cropped yet (= the whole frame),
/// else renders the uncropped frame small, off the main thread.
private struct BulkCropPreviewGrid: View {
    let model: AppModel
    let ids: [Int64]
    let options: BulkCropOptions?

    var body: some View {
        let photos = ids.compactMap { PhotoActions.photo($0, model) }
        HStack(alignment: .center, spacing: 8) {
            ForEach(photos) { photo in
                BulkCropPreviewCell(photo: photo, catalog: model.catalog, options: options)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help("Preview of the first \(photos.count) photos with the new crop")
    }
}

private struct BulkCropPreviewCell: View {
    let photo: Photo
    let catalog: Catalog
    let options: BulkCropOptions?
    @State private var frameImage: CGImage?

    var body: some View {
        let settings = photo.editSettings
        let math = CropMath(sourceSize: photo.orientedSize, geometry: settings.geometry)
        let frame = math.frameSize
        let aspect = frame.height > 0 ? frame.width / frame.height : 1
        let newCrop = options.flatMap { BulkCrop.apply($0, to: settings, sourceSize: photo.orientedSize) }?.geometry.crop
        VStack(spacing: 3) {
            ZStack {
                if settings.geometry.crop.isFull {
                    ThumbnailView(photo: photo, level: .thumbnail)
                } else if let frameImage {
                    Image(decorative: frameImage, scale: 1).resizable()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { if let newCrop { CropMaskOverlay(crop: newCrop) } }
            .frame(width: 80, height: 80)
            Text(photo.displayTitle).font(.system(size: 9)).lineLimit(1).truncationMode(.middle).frame(width: 80)
        }
        .task(id: photo.id) { await loadFrame(settings) }
    }

    /// The uncropped frame of an already cropped photo (its thumbnail shows only the old crop).
    private func loadFrame(_ settings: EditSettings) async {
        guard !settings.geometry.crop.isFull, frameImage == nil else { return }
        var uncropped = settings
        uncropped.geometry.crop = .full
        let photo = photo, catalog = catalog
        frameImage = await Task.detached(priority: .userInitiated) {
            let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
            return RenderPipeline.renderCGImage(url: url, settings: uncropped, maxPixelSize: 240)
        }.value
    }
}

/// Dims everything outside `crop` (normalized, top-left origin) and outlines it.
private struct CropMaskOverlay: View {
    let crop: NormRect

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(x: crop.x * geo.size.width, y: crop.y * geo.size.height,
                           width: crop.width * geo.size.width, height: crop.height * geo.size.height)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRect(r)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle().path(in: r).stroke(.white, lineWidth: 1)
        }
    }
}
