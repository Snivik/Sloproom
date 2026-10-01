//
//  actions_check.swift
//  Headless checks for the photo actions primitive (Actions/): registry (arity, modes,
//  enablement, shortcut titles), target resolution, Bulk Crop math (match / as written,
//  portrait / landscape / square, rotated / straightened / flipped / EXIF-rotated photos, every
//  default preset + Original + custom), section masking for Paste / Sync Settings, and the bulk
//  edit engine incl. one-step undo / redo on a temp catalog (+ timing).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/actions-out/actions_check Tools/actions_check.swift \
//      sloproom/Actions/PhotoActionSpec.swift sloproom/Actions/EditSections.swift sloproom/Actions/BulkCrop.swift \
//      sloproom/Actions/Catalog+BulkEdits.swift sloproom/Shortcuts/ShortcutModel.swift \
//      sloproom/Develop/Crop/CropMath.swift sloproom/Develop/Crop/Catalog+CropPresets.swift
//    /private/tmp/claude-501/actions-out/actions_check [out-dir]
//

import Foundation
import CoreGraphics

@main
struct ActionsCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/private/tmp/claude-501/actions-out/run")
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        registryChecks()
        targetChecks()
        bulkCropChecks()
        sectionChecks()
        try catalogChecks(outDir: outDir)

        print(failures == 0 ? "ALL ACTIONS CHECKS PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Registry

    static func registryChecks() {
        print("Registry: arity, modes, enablement")
        check(PhotoActionArity.single.accepts(1) && !PhotoActionArity.single.accepts(0) && !PhotoActionArity.single.accepts(2), "single = exactly one")
        check(PhotoActionArity.multiple.accepts(1) && PhotoActionArity.multiple.accepts(500) && !PhotoActionArity.multiple.accepts(0), "multiple = one or more")
        check(PhotoActionArity.many.accepts(2) && !PhotoActionArity.many.accepts(1) && !PhotoActionArity.many.accepts(0), "many = two or more")
        check(PhotoActionArity.single.disabledReason(3) == "Select a single photo", "single with 3: \"Select a single photo\"")
        check(PhotoActionArity.many.disabledReason(1) == "Select two or more photos", "many with 1: \"Select two or more photos\"")

        let all = PhotoActionSpec.all
        check(Set(all.map(\.id)).count == all.count, "ids unique")
        check(Set(all.map(\.id)) == Set(PhotoActionID.allCases), "every PhotoActionID is registered")
        let singles = Set(all.filter { $0.arity == .single }.map(\.id))
        check(singles == [.openInDevelop, .showInFinder, .renameVirtualCopy, .copySettings], "single actions: \(singles.map(\.rawValue).sorted())")
        check(Set(all.filter { $0.arity == .many }.map(\.id)) == [.syncSettings], "many actions: Sync Settings")
        check(all.map(\.group) == all.map(\.group).sorted(), "registry is in menu-group order")

        // Menu bar items with a menu-command shortcut must carry exactly the shortcut's title
        // (ShortcutMenuSync patches key equivalents by title).
        for spec in all where spec.inMenuBar {
            if let s = spec.shortcut, s.isMenuCommand {
                check(spec.menuTitle == s.title, "menu title \"\(spec.menuTitle)\" == shortcut title \"\(s.title)\"")
            }
        }
        check(ShortcutAction.bulkCrop.isMenuCommand && ShortcutAction.bulkCrop.defaultBinding == nil, "Bulk Crop: menu command, no default key (assignable)")
        check(ShortcutAction.syncSettings.defaultBinding == KeyCombo("s", [.command, .shift]), "Sync Settings ⇧⌘S")
        check(ShortcutAction.resetEdits.defaultBinding == KeyCombo("r", [.command, .shift]), "Reset Edits ⇧⌘R")
        check(ShortcutAction.showInFinder.defaultBinding == KeyCombo("r", .command), "Show in Finder ⌘R")
        // No default-binding conflicts introduced (same key, overlapping scopes, neither narrower).
        let bound = ShortcutAction.allCases.compactMap { a in a.defaultBinding.map { (a, $0) } }
        var conflicts: [String] = []
        for (i, (a, ka)) in bound.enumerated() {
            for (b, kb) in bound[(i + 1)...] where ka.overlaps(kb) && a.scope.conflicts(with: b.scope)
                && !(a.focusGroup != nil && b.focusGroup != nil && a.focusGroup != b.focusGroup) {
                conflicts.append("\(a.id)/\(b.id) \(ka.display)")
            }
        }
        check(conflicts.isEmpty, "no conflicting default bindings \(conflicts)")

        // Develop, 3 selected: multi actions enabled, single ones disabled with a reason, Open in
        // Develop hidden.
        let dev3 = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.availability(count: 3, mode: .develop)) })
        check(dev3[.openInDevelop] == .hidden, "Develop: Open in Develop hidden")
        check(dev3[.showInFinder] == .disabled("Select a single photo") && dev3[.copySettings] == .disabled("Select a single photo")
              && dev3[.renameVirtualCopy] == .disabled("Select a single photo"), "Develop ×3: single actions disabled (\"Select a single photo\")")
        check([.pick, .bulkCrop, .pasteSettings, .resetEdits, .syncSettings, .addToFolder, .copyToFolder, .exportJPEG, .createVirtualCopy]
                .allSatisfy { dev3[$0] == .enabled }, "Develop ×3: multi actions + Sync enabled")
        let lib1 = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.availability(count: 1, mode: .library)) })
        check(lib1[.syncSettings] == .disabled("Select two or more photos") && lib1[.openInDevelop] == .enabled && lib1[.copySettings] == .enabled,
              "Library ×1: Sync disabled, Open in Develop / Copy Settings enabled")
        check(all.allSatisfy { $0.availability(count: 0, mode: .library) != .enabled }, "nothing enabled with 0 targets")
        let titles = (PhotoActionSpec.spec(.pick).title(count: 12), PhotoActionSpec.spec(.pick).title(count: 1),
                      PhotoActionSpec.spec(.bulkCrop).title(count: 6), PhotoActionSpec.spec(.syncSettings).title(count: 4))
        check(titles == ("Pick 12 Photos", "Pick", "Bulk Crop 6 Photos…", "Sync Settings to 3 Photos…"), "count titles \(titles)")
    }

    // MARK: - Targets

    static func targetChecks() {
        print("Target resolution")
        typealias T = PhotoActionTargets
        let sel: [Int64] = [3, 5, 8]
        check(T.resolve(mode: .library, orderedSelection: sel, focusedID: 5).ids == sel, "Library: the selection")
        check(T.resolve(mode: .library, orderedSelection: sel, focusedID: 5).primaryID == 5, "Library: primary = focused")
        check(T.resolve(mode: .library, orderedSelection: [], focusedID: 9).ids == [9], "Library: no selection → focused")
        check(T.resolve(mode: .library, orderedSelection: [], focusedID: nil).ids.isEmpty, "Library: nothing")
        let outside = T.resolve(mode: .library, orderedSelection: sel, focusedID: 5, clickedID: 7)
        check(outside.ids == [7] && outside.clickedOutsideSelection, "Library: right-click outside the selection → that cell")
        check(T.resolve(mode: .library, orderedSelection: sel, focusedID: 5, clickedID: 8).ids == sel, "Library: right-click inside → selection")
        check(T.resolve(mode: .develop, orderedSelection: sel, focusedID: 5).ids == sel, "Develop: multi-selection incl. edited photo → selection")
        check(T.resolve(mode: .develop, orderedSelection: [5], focusedID: 5).ids == [5], "Develop: single → edited photo")
        check(T.resolve(mode: .develop, orderedSelection: [3, 8], focusedID: 5).ids == [5], "Develop: edited photo not in selection → edited photo")
        check(T.resolve(mode: .develop, orderedSelection: sel, focusedID: 5, clickedID: 3).ids == sel, "Develop strip: right-click in multi-selection → selection")
        check(T.resolve(mode: .develop, orderedSelection: [5], focusedID: 5, clickedID: 5).ids == [5], "Develop strip: right-click the edited photo")
        check(T.resolve(mode: .develop, orderedSelection: [5], focusedID: 5, clickedID: 9).ids == [9], "Develop strip: right-click another cell → that cell")
        check(T.resolve(mode: .develop, orderedSelection: sel, focusedID: 8).primaryID == 8, "Develop: primary (Sync source) = edited photo")
    }

    // MARK: - Bulk crop

    static func aspectOf(_ s: EditSettings, _ size: CGSize) -> CGFloat {
        let m = CropMath(sourceSize: size, geometry: s.geometry)
        let r = m.pixelRect(s.geometry.crop)
        return r.width / r.height
    }

    static func bulkCropChecks() {
        print("Bulk Crop math")
        let landscape = CGSize(width: 6000, height: 4000), portrait = CGSize(width: 4000, height: 6000), square = CGSize(width: 3000, height: 3000)
        let presets: [(String, Double, Double)] = [("Instagram Story 9:16", 9, 16), ("Instagram Post Square 1:1", 1, 1), ("Vertical 4:5", 4, 5),
                                                   ("Horizontal 3:2", 3, 2), ("Horizontal 16:9", 16, 9), ("custom 7:3", 7, 3)]
        var bad: [String] = []
        for (name, w, h) in presets {
            for orientation in BulkCropOptions.Orientation.allCases {
                for (label, size, turns, angle, flip) in [("landscape", landscape, 0, 0.0, false), ("portrait", portrait, 0, 0.0, false),
                                                          ("square", square, 0, 0.0, false), ("landscape+90°", landscape, 1, 0.0, false),
                                                          ("portrait+270°", portrait, 3, 0.0, false), ("landscape straightened 8°", landscape, 0, 8.0, false),
                                                          ("portrait −13° flipped", portrait, 0, -13.0, true), ("landscape 180° −45°", landscape, 2, -45.0, false)] {
                    var s = EditSettings()
                    s.geometry.quarterTurns = turns
                    s.geometry.straightenAngle = angle
                    s.geometry.flipHorizontal = flip
                    s.geometry.crop = NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)   // replaced
                    s.tone.exposure = 0.7                                                  // kept
                    let opts = BulkCropOptions(ratio: .ratio(width: w, height: h, presetID: 42), orientation: orientation)
                    guard let out = BulkCrop.apply(opts, to: s, sourceSize: size) else { bad.append("\(name) \(label) nil"); continue }
                    let math = CropMath(sourceSize: size, geometry: out.geometry)
                    let frame = math.frameSize
                    var want = w / h
                    if orientation == .matchPhoto, w != h, frame.width != frame.height, (frame.height > frame.width) != (want < 1) { want = 1 / want }
                    let rect = math.pixelRect(out.geometry.crop)
                    let got = Double(rect.width / rect.height)
                    let centered = abs(rect.midX - frame.width / 2) < 1e-6 * frame.width && abs(rect.midY - frame.height / 2) < 1e-6 * frame.height
                    let inside = math.contains(rect.insetBy(dx: frame.width * 1e-7, dy: frame.height * 1e-7))
                    let maximal = math.maxScale(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.size) < 1.0001
                    let kept = out.geometry.quarterTurns == turns && out.geometry.straightenAngle == angle && out.geometry.flipHorizontal == flip
                        && out.tone == s.tone && out.geometry.cropPresetID == 42 && out.geometry.aspectLocked
                    if abs(got / want - 1) > 1e-6 || !centered || !inside || !maximal || !kept {
                        bad.append("\(name) \(orientation.rawValue) \(label): aspect \(got) want \(want) centered=\(centered) inside=\(inside) maximal=\(maximal) kept=\(kept)")
                    }
                }
            }
        }
        check(bad.isEmpty, "every preset × orientation option × photo shape / rotation: right aspect, centered, inside the rotated content, largest, rest kept (\(presets.count * 2 * 8) cases)\(bad.isEmpty ? "" : "\n    " + bad.joined(separator: "\n    "))")

        // Spelled-out expectations.
        let match = BulkCropOptions(ratio: .ratio(width: 4, height: 5, presetID: nil), orientation: .matchPhoto)
        check(abs(aspectOf(BulkCrop.apply(match, to: EditSettings(), sourceSize: portrait)!, portrait) - 0.8) < 1e-9, "4:5 match: portrait photo → 4:5")
        check(abs(aspectOf(BulkCrop.apply(match, to: EditSettings(), sourceSize: landscape)!, landscape) - 1.25) < 1e-9, "4:5 match: landscape photo → 5:4")
        let story = BulkCropOptions(ratio: .ratio(width: 9, height: 16, presetID: nil), orientation: .asWritten)
        check(abs(aspectOf(BulkCrop.apply(story, to: EditSettings(), sourceSize: landscape)!, landscape) - 9.0 / 16) < 1e-9, "9:16 as written: landscape photo → 9:16")
        let full = BulkCrop.apply(story, to: EditSettings(), sourceSize: landscape)!.geometry.crop
        check(abs(full.height - 1) < 1e-9 && abs(full.x - (1 - full.width) / 2) < 1e-9, "9:16 on a 3:2 landscape: full height, centered (x=\(full.x))")
        var rotated = EditSettings(); rotated.geometry.quarterTurns = 1
        check(abs(aspectOf(BulkCrop.apply(match, to: rotated, sourceSize: landscape)!, landscape) - 0.8) < 1e-9, "landscape rotated 90° counts as portrait → 4:5")
        // EXIF orientation 6 (stored 6000×4000, displayed portrait): callers pass orientedSize.
        var exif = Photo(path: "/x/a.dng"); exif.width = 6000; exif.height = 4000; exif.orientation = 6
        check(abs(aspectOf(BulkCrop.apply(match, to: EditSettings(), sourceSize: exif.orientedSize)!, exif.orientedSize) - 0.8) < 1e-9, "EXIF-rotated portrait (orientation 6) → 4:5")

        var cropped = EditSettings(); cropped.geometry.crop = NormRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5); cropped.geometry.cropPresetID = 3
        let original = BulkCrop.apply(BulkCropOptions(ratio: .original), to: cropped, sourceSize: landscape)!
        check(original.geometry.crop == .full && original.geometry.cropPresetID == nil, "Original on an unstraightened photo removes the crop")
        var straight = cropped; straight.geometry.straightenAngle = 5
        let os = BulkCrop.apply(BulkCropOptions(ratio: .original), to: straight, sourceSize: landscape)!
        check(abs(aspectOf(os, landscape) - 1.5) < 1e-6 && os.geometry.crop.width < 1, "Original on a straightened photo: largest 3:2 inside the rotated image")
        check(BulkCrop.apply(match, to: EditSettings(), sourceSize: .zero) == nil, "unknown size → skipped")
    }

    // MARK: - Sections

    static func sectionChecks() {
        print("Paste / Sync section masking")
        var src = EditSettings()
        src.whiteBalance.mode = .custom; src.whiteBalance.temperature = 4100
        src.tone.exposure = 1.2; src.presence.clarity = 30; src.colorMixer[.blue].saturation = -40
        src.effects.vignetteAmount = -20
        src.masks = [testMask()]
        src.geometry.crop = NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8); src.geometry.quarterTurns = 1
        var dst = EditSettings()
        dst.tone.contrast = 15; dst.geometry.straightenAngle = 3; dst.masks = [testMask(), testMask()]
        for section in EditSection.allCases {
            let out = dst.replacing([section], from: src)
            check(out.differingSections(from: dst) == [section] && out.differingSections(from: src) == Set(EditSection.allCases).subtracting([section]),
                  "\(section.title): only that section copied")
        }
        let pasted = dst.replacing(EditSection.pasteDefault, from: src)
        check(pasted.geometry == dst.geometry && pasted.masks == dst.masks && pasted.tone == src.tone && pasted.whiteBalance == src.whiteBalance,
              "Paste default = global adjustments (target keeps its crop and masks)")
        let synced = dst.replacing(EditSection.syncDefault, from: src)
        check(synced.geometry == dst.geometry && synced.masks == src.masks, "Sync default: crop off, masks on")
        check(dst.replacing(Set(EditSection.allCases), from: src).differingSections(from: src).isEmpty, "all sections → equals the source")
        check(dst.replacing([], from: src) == dst, "no sections → unchanged")
        check(EditSection.decode(EditSection.encode([.tone, .masks])) == [.tone, .masks] && EditSection.decode("") == [] && EditSection.decode(nil) == nil,
              "checklist persistence round trip")
    }

    // MARK: - Catalog: bulk apply + one-step undo / redo

    static func catalogChecks(outDir: URL) throws {
        print("Bulk edit engine + undo restore (temp catalog)")
        let catalog = try Catalog.open(at: outDir.appendingPathComponent("cat"))
        try catalog.ensureDefaultCropPresets()
        let presets = try catalog.allCropPresets()
        check(Set(presets.map(\.name)).isSuperset(of: ["Horizontal 16:9"]) && presets.count >= 5, "default presets: \(presets.map(\.name))")

        var photos: [Photo] = []
        for i in 0..<12 {
            var p = Photo(path: "/bulk/IMG_\(i).DNG")
            p.width = i % 3 == 0 ? 4000 : 6000; p.height = i % 3 == 0 ? 6000 : 4000
            p.orientation = i == 4 ? 6 : 1
            photos.append(p)
        }
        photos[11].width = 0; photos[11].height = 0          // unknown size → skipped
        let ids = try catalog.insertPhotos(photos)
        // Some photos have edits already (one with a crop, one with masks), the rest none (NULL).
        var edited = EditSettings(); edited.tone.exposure = 0.5; edited.geometry.crop = NormRect(x: 0, y: 0, width: 0.5, height: 0.5)
        try catalog.saveEditSettings(edited, for: ids[1])
        var masked = EditSettings(); masked.masks = [testMask()]; masked.geometry.quarterTurns = 1
        try catalog.saveEditSettings(masked, for: ids[2])
        let beforeJSON = try ids.map { try catalog.photo(id: $0)?.editSettingsJSON }
        let beforeVersions = try ids.map { try catalog.photo(id: $0)?.editVersion ?? -1 }

        let story = presets.first { $0.ratioW == 9 && $0.ratioH == 16 }!   // "Instagram Story"
        let opts = BulkCropOptions(ratio: .ratio(width: story.ratioW, height: story.ratioH, presetID: story.id), orientation: .matchPhoto)
        var ticks: [(Int, Int)] = []
        let change = try BulkEdit.apply(catalog: catalog, ids: ids, transform: { photo, s in
            BulkCrop.apply(opts, to: s, sourceSize: photo.orientedSize)
        }, progress: { ticks.append(($0, $1)) })
        check(change.ids.count == 11 && change.skipped == [ids[11]], "11 cropped, the size-less photo skipped")
        check(change.before[ids[0]]! == nil && change.before[ids[1]]! == edited && change.before[ids[2]]! == masked, "before = stored settings (nil for NULL rows)")
        check(ticks.last.map { $0 == (12, 12) } ?? false, "progress reaches total")
        var allOK = true
        for (i, id) in ids.enumerated().dropLast() {
            let p = try catalog.photo(id: id)!
            let s = p.editSettings
            let size = p.orientedSize
            let frame = CropMath(sourceSize: size, geometry: s.geometry).frameSize
            let want = frame.height > frame.width ? 9.0 / 16 : 16.0 / 9
            if abs(aspectOf(s, size) / want - 1) > 1e-6 || s.geometry.cropPresetID != story.id || p.editVersion != beforeVersions[i] + 1 { allOK = false; print("    photo \(i): \(aspectOf(s, size)) want \(want) v\(p.editVersion)") }
        }
        check(allOK, "every photo cropped to 9:16 / 16:9 by its orientation (EXIF + quarter turns), preset set, edit_version +1")
        check(try catalog.photo(id: ids[1])!.editSettings.tone.exposure == 0.5 && catalog.photo(id: ids[2])!.editSettings.masks.count == 1,
              "other sections untouched")

        // Undo: ONE write of `before` restores all of them.
        try BulkEdit.write(change.before, order: change.ids, catalog: catalog)
        let undoneJSON = try ids.map { try catalog.photo(id: $0)?.editSettingsJSON }
        check(zip(beforeJSON, undoneJSON).allSatisfy { a, b in EditSettings.fromJSON(a) == EditSettings.fromJSON(b) && (a == nil) == (b == nil) },
              "undo restores every photo's previous settings (NULL rows back to NULL)")
        check(try catalog.photo(id: ids[0])!.editVersion == beforeVersions[0] + 2, "undo bumps edit_version again (previews regenerate)")
        try BulkEdit.write(change.after, order: change.ids, catalog: catalog)
        check(try ids.dropLast().allSatisfy { id in try catalog.photo(id: id)!.editSettings == change.after[id]!! }, "redo re-applies the crops")

        // `current` override (the photo open in Develop has newer unsaved settings).
        var live = EditSettings(); live.tone.exposure = 2
        let c2 = try BulkEdit.apply(catalog: catalog, ids: [ids[0]], current: [ids[0]: live]) { _, s in s.replacing([.tone], from: EditSettings()) }
        let exposureAfter = try catalog.photo(id: ids[0])!.editSettings.tone.exposure
        check(c2.before[ids[0]]! == live && exposureAfter == 0, "current settings override the stored ones")

        // Reset to defaults stores NULL; unchanged results are skipped.
        let c3 = try BulkEdit.apply(catalog: catalog, ids: [ids[3], ids[11]]) { _, _ in EditSettings() }
        check(try catalog.photo(id: ids[3])!.editSettingsJSON == nil && c3.after[ids[3]]! == nil, "reset stores NULL")
        check(c3.skipped == [ids[11]], "unchanged photo skipped")

        // Timing: 2,000 photos.
        var many: [Photo] = []
        for i in 0..<2000 { var p = Photo(path: "/bulk/many/\(i).DNG"); p.width = 6000; p.height = 4000; many.append(p) }
        let manyIDs = try catalog.insertPhotos(many)
        let t0 = Date()
        let big = try BulkEdit.apply(catalog: catalog, ids: manyIDs) { p, s in BulkCrop.apply(opts, to: s, sourceSize: p.orientedSize) }
        let t1 = Date()
        try BulkEdit.write(big.before, order: big.ids, catalog: catalog)
        let t2 = Date()
        print(String(format: "    2,000 photos: apply %.0f ms, undo %.0f ms", t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
        let lastJSON = try catalog.photo(id: manyIDs[1999])!.editSettingsJSON
        check(big.ids.count == 2000 && lastJSON == nil, "2,000 photos applied and undone")
    }
}

private func testMask() -> Mask {
    Mask(shape: .linear(LinearGradientMask(start: NormPoint(x: 0.5, y: 0), end: NormPoint(x: 0.5, y: 0.6))))
}
