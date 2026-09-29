# Sloproom architecture

Personal Lightroom-Classic-like photo app. SwiftUI, macOS 26, Apple Silicon, no third-party deps.
This document describes the merged system (foundation + import, Lightroom import, folders/flags,
previews, develop engine, masks, crop). If you change a contract below, update this file in the
same commit.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project sloproom.xcodeproj \
  -scheme sloproom -configuration Debug -derivedDataPath /private/tmp/claude-501/dd-<you> build \
  2>&1 | grep -E "error|warning: |BUILD" | head -50
```

- Files under `sloproom/` are auto-included (file-system synchronized groups). Never edit `project.pbxproj`.
- Swift 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency,
  `MemberImportVisibility` (every file imports what it uses: `Foundation`, `CoreGraphics`, `CoreImage`, …).
- Anything that runs off-main (engine, services, value types) is declared `nonisolated`
  (`nonisolated final class X: @unchecked Sendable`, `nonisolated struct Y: Sendable`).
- App Sandbox ON, user-selected files READ-ONLY (owner will switch to read/write). Don't change entitlements.
- Headless tests: see `Tools/README.md` (`Tools/harness.sh`, `Tools/foundation_check.swift`,
  sandboxed UI runs with `SLOPROOM_CATALOG_DIR` + `SLOPROOM_DEV_SCRIPT` snapshots, catalog + photos inside the app container. NEVER build with the sandbox disabled).

## Module map

| Path | What |
|---|---|
| `App/sloproomApp.swift` | scene: main `Window` (+ `SloproomCommands`, `PreviewCommands`), `Settings` (tabs Previews, Drives) |
| `App/AppModel.swift`, `FolderTree.swift`, `SloproomCommands.swift` | app state, folder tree, menu bar (+ `TextInputGuard`) |
| `App/DevTools.swift`, `App/IntegrationDevScript.swift` | "Add Folder in Place (Dev)", `DevScript` (DEBUG UI scripting); feature DevScript files live next to their feature |
| `Catalog/*` | SQLite wrapper, catalog open/migrate, photos / folders / roots / crop-preset API, models, security scope |
| `Import/*` | SD card / folder import: engine (`ImportEngine`), sheet state (`ImportSession`), sources, sheet UI, EXIF reader (`PhotoMetadataReader`) |
| `LightroomImport/*` | Lightroom Classic catalog import (structure only), root access status / grants (`RootAccess`, `RootsAccessView`) |
| `Library/*` | main window, grid, cells, filmstrip, sidebar; `ThumbnailView` (the only preview loader) |
| `Library/Sidebar/*` | folder management (create/rename/delete/move/reorder, DnD, context menus), sidebar state, folders DevScript (key/click synthesis) |
| `Library/Flags/*` | flag actions (auto-advance), grid filter bar, `LibraryKeyMonitor` (D, ⌘A) |
| `Previews/*` (+ `Previews/UI/*`) | preview service, disk cache, lanes, build jobs, settings (+ settings view, Library > Previews menu, toolbar activity) |
| `Develop/EditSettings.swift`, `GeometryMath.swift`, `CanvasGeometry.swift`, `RenderPipeline.swift` | edit model, geometry maps, render pipeline |
| `Develop/Stages/*` | the 7 render stages + `LocalAdjustmentRenderer` |
| `Develop/Adjustments/*`, `Develop/Kernels/*` | adjustment ops, Metal CI kernels, histogram, WB estimator, baseline exposure; `Adjustments/UI/*` clipboard, WB picker, histogram view, DevScript |
| `Develop/Masking/*` (+ `Masking/UI/*`) | mask rasterization (engine) + mask tool state/interaction/coverage overlay |
| `Develop/Crop/*` | crop math, crop actions on `DevelopSession`, preset catalog API + editor, `CropKeyMonitor` |
| `Develop/DevelopSession.swift`, `DevelopView/Canvas/Inspector`, `DevelopSlider`, `Panels/*`, `Overlays/*` | develop session + UI |
| `Export/ExportEngine.swift` (+ `Export/UI/*`) | JPEG export engine (+ sheet, controller, File > Export… / context menu, DevScript) |

Conventions: new catalog API as `nonisolated extension Catalog` in the feature's own
`Catalog+Feature.swift`; feature tables via `applyMigration(named:sql:)`; engine files (anything
a harness compiles) import no SwiftUI/AppKit and mark types `nonisolated`.

## Catalog

`nonisolated final class Catalog: @unchecked Sendable`. All methods are synchronous, thread-safe
(one recursive lock in `SQLiteDatabase`) and `throws`. Call heavy ones off the main thread.

- Location: `Catalog.defaultDirectory` = `<Application Support>/Sloproom` (inside the container when
  sandboxed; `SLOPROOM_CATALOG_DIR` env overrides). `catalogDirectory` holds `Catalog.sqlite`;
  `cacheDirectory("Previews")` returns/creates a subdirectory for caches.
- Open: `Catalog.openDefault()`, `Catalog.open(at: URL)` (harnesses: temp dir).
- Schema: `PRAGMA user_version` migrations in `Catalog.migrations` (append-only, foundation-owned).
  Feature tables: `try catalog.applyMigration(named: "previews.v1", sql: "CREATE TABLE …")` —
  idempotent, tracked in `applied_migrations`.
- Tables: `photos`, `folders`, `folder_photos`, `roots`, `crop_presets`, `applied_migrations`
  (see `Catalog.swift` for DDL). Dates are REAL Unix seconds. `photos.flag`: -1 reject, 0 none, 1 pick.
  `photos.edit_version` increments on every `saveEditSettings`. `photos.root_id` → `roots` ON DELETE SET NULL.
  `folders.parent_id` and `folder_photos.*` cascade on delete. Foreign keys ON, WAL.
- Raw access for extensions: `catalog.db.run(sql, args)`, `db.query(sql, args) { row in … }`,
  `db.scalarInt`, `db.transaction { }`, `db.lastInsertRowID`. Bind with Int/Int64/Double/String/
  Data/Bool/Date/Optional or `SQLValue.null`. Select photos with `Catalog.photoColumns` (alias `p`)
  and map with `Photo(row:)`.

### API summary

```swift
// Photos
func insertPhoto(_ photo: Photo) throws -> Int64                 // upsert by path: existing id if present
func insertPhotos(_ photos: [Photo]) throws -> [Int64]           // one transaction; ids in input order
func photo(id: Int64) throws -> Photo?
func photos(ids: [Int64]) throws -> [Photo]
func photoID(path: String) throws -> Int64?
func photoIDExists(path: String) throws -> Bool
func totalPhotoCount() throws -> Int
func photos(in: PhotoSource, filter: PhotoFilter = .init(), sort: PhotoSort = .init()) throws -> [Photo]
func setFlag(_ flag: Flag, for photoIDs: some Collection<Int64>) throws
func setRating(_ rating: Int, for photoIDs: some Collection<Int64>) throws     // clamped 0...5
func setSidecarPath(_ path: String?, for photoID: Int64) throws
func saveEditSettings(_ settings: EditSettings?, for photoID: Int64) throws -> Int  // new edit_version; nil / EditSettings() (isEmpty) → NULL
func removePhotos(ids: some Collection<Int64>) throws           // catalog only, never files

// Folders (virtual, nested; a photo can be in many; deleting never deletes photos)
func allFolders() throws -> [Folder]                             // flat; build tree with FolderTree.build
func folder(id: Int64) throws -> Folder?
func createFolder(name: String, parentID: Int64? = nil, lrCollectionID: Int64? = nil) throws -> Int64
func renameFolder(id: Int64, to name: String) throws
func moveFolder(id: Int64, toParent: Int64?, index: Int? = nil) throws   // throws CatalogError.folderCycle
func deleteFolder(id: Int64) throws                              // cascades subfolders + memberships
func folderSubtreeIDs(_ id: Int64) throws -> [Int64]
func addPhotos(_ ids: some Collection<Int64>, toFolder: Int64) throws    // appends, ignores duplicates
func removePhotos(_ ids: some Collection<Int64>, fromFolder: Int64) throws
func movePhotos(_ ids: some Collection<Int64>, from: Int64, to: Int64) throws
func photoCount(folderID: Int64, includeSubfolders: Bool = false) throws -> Int
func folderPhotoCounts() throws -> [Int64: Int]                  // direct counts, absent = 0
func folderIDs(containing photoID: Int64) throws -> [Int64]

// Roots (security-scoped disk locations)
func upsertRoot(path: String, bookmark: Data?, displayName: String? = nil) throws -> Int64  // attaches root-less photos under it
static func normalizedPath(_:) -> String                        // THE root↔photo path normalization (see below)
func updateRootBookmark(id: Int64, bookmark: Data) throws
func allRoots() throws -> [Root];  func root(id: Int64) throws -> Root?
func root(for path: String) throws -> Root?                      // longest-prefix match
func removeRoot(id: Int64) throws

// Crop presets ("Original" is built into the UI, never stored)
func allCropPresets() throws -> [CropPreset]
func createCropPreset(name: String, ratioW: Double, ratioH: Double) throws -> Int64
func updateCropPreset(_ preset: CropPreset) throws;  func deleteCropPreset(id: Int64) throws
```

`PhotoSource`: `.all`, `.folder(id:includeSubfolders:)` (distinct photos of the subtree),
`.lastImport` (photos whose `import_date` equals the max — **importers must use one `importDate`
for all photos of an import session**). `PhotoFilter { flag: FlagFilter (.all/.picked/.rejected/
.unflagged/.notRejected), minRating }`. `PhotoSort { key: .captureDate/.importDate/.fileName/.folderOrder, ascending }`.

Paths: roots are stored normalized with `Catalog.normalizedPath` (standardized, no trailing slash,
`/private/var|tmp|etc` → `/var|tmp|etc` deterministically); photo paths are stored as given and
normalized with the same function whenever they are matched to roots (`coveringRoot`, `root(for:)`,
`upsertRoot`), so `/private/tmp/x` photos attach to a `/tmp/x` root.

`Photo` notes: `width/height` are stored (un-oriented) pixels; `orientedSize` applies EXIF
orientation; `editSettings` decodes `editSettingsJSON` (defaults if nil); `hasEdits`; `url`, `sidecarURL`.

### Change notifications

Every mutating call posts `Catalog.didChange` **on the main queue** (async), `object` = the catalog,
payload `Catalog.change(from: note) -> CatalogChange?`:

| case | posted by |
|---|---|
| `.photosUpdated(Set<Int64>)` | setFlag, setRating, setSidecarPath, saveEditSettings |
| `.photosInsertedOrRemoved` | insertPhotos (if anything new), removePhotos |
| `.folders` | create/rename/move/delete folder |
| `.folderMembership(Set<Int64>)` | add/remove/move photos in folders |
| `.roots`, `.cropPresets` | roots / preset CRUD |

Your own extension methods should call `postChange(_:)` too. `AppModel` coalesces bursts and reloads
(`.roots` reloads photos too: root ids change when a granted parent folder replaces inner roots).
`PreviewService` also observes `.roots`: it clears `SecurityScopeManager` failures and bumps the
`PreviewJobs` revision of photos that were offline, so their thumbnails retry without a restart.

## Sandbox / security scope

- The catalog lives in the container. Photo files are only readable via user grants.
- A **root** = a folder/volume the user picked. Right after an `NSOpenPanel` returns, call
  `SecurityScopeManager.shared.registerRoot(url:in:)` → creates a security-scoped bookmark, upserts the
  root, starts access.
- **Before reading any photo file**: `let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)`
  (or `SecurityScope.withAccess(to: url, catalog:) { }`). The manager resolves the covering root's
  bookmark once, keeps the scope open for the app's lifetime, refreshes stale bookmarks. Thread-safe.
- Bookmarks are created read/write when possible, else read-only. Copying files (SD import) will need
  the read/write entitlement the owner will enable later; the destination folder must also be a root.
- Paths with no covering root are accessed directly (works in the container and unsandboxed harnesses).
- A stale `photo.rootID` (root replaced) falls back to the currently covering root.
- Granting access to an existing root: `RootAccess.grant(_:pickedURL:catalog:)` (used by
  `RootsAccessView`, shown in the Lightroom import sheet and in Settings > Drives). Picking a parent
  folder / the whole drive replaces bookmark-less inner roots.

## App state (`App/AppModel.swift`, MainActor, `@Observable`)

Injected with `.environment(model)`; views use `@Environment(AppModel.self)`.

- `catalog`, `folders`, `folderTree: [FolderNode]`, `folderCounts`, `totalPhotoCount`
- `selectedSource`, `includeSubfolders`, `filter`, `sort` (setting any reloads `photos`)
- `photos: [Photo]`, `photo(id:)`, `index(of:)`, `selection: Set<Int64>`, `focusedPhotoID`, `focusedPhoto`
- `mode: AppMode (.library/.develop)` — entering develop opens `developSession` for the focused photo;
  changing `focusedPhotoID` in develop switches the session (pending edits are saved first).
- `presentedSheet: SheetKind? (.importPhotos/.importLightroom/.previewSettings)` → `MainWindowView` presents
  `ImportPhotosSheet`, `LightroomImportSheet`, `PreviewSettingsView`.
- Actions: `setFlag(_:)`, `setRating(_:)` act on `actionTargetIDs` (library: selection or focused;
  develop: the filmstrip selection when the current photo is part of a multi-selection, else the
  current photo; `orderedSelection` = selection in list order); `click(photoID:command:shift:)`
  (grid AND filmstrip; ⌘-click deselecting the focused photo moves focus to the nearest selected
  one), `selectAll()`, `moveFocus(by:extend:)`,
  `createFolder(name:parentID:)`, `openInDevelop(_:)`, `report(_ error:)` (alert).
- Reloads are synchronous on main (fine for tens of thousands of rows; move off-main if needed).
  Catalog-change reloads are "in place": a focused photo that drops out of the list (unpicked under
  the Picked filter, removed…) hands focus (and the selection, if it emptied) to the next remaining
  photo of the old list, or the previous one if it was last. Source / filter / sort changes don't.

Menus (`SloproomCommands` + `PreviewCommands` + `ExportCommands`): File > New Folder (⇧⌘N), Import Photos… (⇧⌘I),
Import Lightroom Catalog…, Add Folder in Place (Dev)…, Export… (⇧⌘E); Edit > Undo/Redo route to the develop session
in Develop mode, otherwise to the responder chain; Edit > Select All Photos (⌥⌘A); Photo > Pick (P),
Unflag (U), Reject (X), Auto Advance After Flagging, Set Rating (0–5), Copy / Paste Settings (⇧⌘C /
⇧⌘V), Before / After (`\`); View > Library (G), Develop (D); Library > Previews ▸ (build / regenerate
/ discard for selection, build all, clean cache). Menu items that act on the selection read
`model.actionTargetIDs` when chosen (menu-bar Commands are not re-rendered on selection changes, so
don't compute `.disabled` from the selection there).

### Keyboard map

Single-letter shortcuts are real menu key equivalents without modifiers (`letterButton`);
`TextInputGuard` re-types the letter into a focused text field instead of running the command.
Local key monitors see keys BEFORE menu matching and all yield while a text field is edited:

| Where | Keys | Handler |
|---|---|---|
| everywhere | P / U / X, 0–5, G, `\`, ⇧⌘C / ⇧⌘V, ⇧⌘N, ⇧⌘I | menu (`SloproomCommands`) |
| main window | D (AppKit's Start Dictation would swallow it), ⌘A in Library | `LibraryKeyMonitor` |
| Library grid (focused) | arrows (+⇧ extend), Return → Develop, ⌫ remove from shown folder / from catalog (confirm) | `LibraryGridView` |
| sidebar (focused) | ⌫ delete folder (confirm) | `SidebarView` |
| Develop | R toggle crop tool, ⌘[ / ⌘] rotate; ←/→ previous / next photo (canvas focused) | `CropKeyMonitor`, `DevelopCanvasView` |
| crop tool | X swap aspect (instead of Reject), O cycle grid, Return commit, Esc cancel | `CropKeyMonitor` |
| mask tool (overlay focused) | O coverage overlay, [ / ] brush size, ⌫ / ⌦ delete selected mask, Esc cancel creation / leave tool | `MaskOverlayView` (Backspace is U+007F: match it by character, `onKeyPress(.delete)` never fires) |
| WB eyedropper | Esc cancel | `WhiteBalancePickerOverlay` |

The toolbar flag-filter menu is shown only in Develop (it filters the filmstrip); Library uses the
`GridFilterBar` (same `model.filter`).

### Folders / flags UI (`Library/Sidebar/*`, `Library/Flags/*`)

- Sidebar rows `SidebarItem` (`.all/.lastImport/.picked/.rejected/.folder`); Picked / Rejected are
  `.all` + `filter.flag` (`model.sidebarItem`, `model.selectSidebarItem(_:)`, `model.shownFolderID`).
- `FolderActions` (create + inline rename, rename, delete, move, add/move/remove photos),
  `FolderSidebarState.shared` (persisted expansion, `renamingFolderID`, pending delete).
- Catalog extras (`Catalog+FolderManagement.swift`): `flagCounts()`, `folderTotalPhotoCounts()`
  (subtree totals, one query), `movePhotos(_:fromFolders:to:)`, `removePhotos(_:fromFolders:)`,
  `uniqueFolderName(_:parentID:)`.
- Flag visuals (`FlagActions.swift`): monochrome white `FlagBadge` on a dark backing (pick = flag,
  reject = flag + ×, hover outline = click to pick in the grid only); `.rejectedVeil(_:)` washes a
  rejected thumbnail out to grey (saturation + `contrast(0.45)` = 55 % mid-grey veil, image pixels
  only). Same in grid (`PhotoGridCell`) and filmstrip (`FilmstripView`, file names under thumbnails,
  focused = bright frame, other selected = light frame).
- Photo drags (grid + filmstrip): `PhotoDrag.provider/preview` (`Library/Flags/PhotoDrag.swift`).
- In-app drag & drop: plain-text `SloproomDragPayload` (`sloproom-drag:photos:1,2` / `…folder:7`)
  in an `NSItemProvider` via `SloproomDrag.provider(_:)`; drop targets decode it with `SloproomDrag.load`.

## EditSettings (`Develop/EditSettings.swift`)

JSON in `photos.edit_settings` (sorted keys). Every field defaults to "no change"; decoding
tolerates missing keys (`c.decode(.key, default:)`), so **add fields with a default and decode them
the same way; never rename/remove keys or change units**. `isDefault` per section and overall =
"renders like the original" (ignores disabled / zero masks, vignette midpoint…); `isEmpty` ==
`EditSettings()` decides persistence (only empty settings are stored as NULL, so a new or hidden mask
survives saving).

| Section | Fields (units / range, default) |
|---|---|
| `whiteBalance` | `mode .asShot/.custom` (asShot ignores temp/tint), `temperature` K 2000…50000 (5500; higher = warmer), `tint` -150…150 (0; + = magenta) |
| `tone` | `exposure` EV -5…5 (applied in RawDecodeStage), `contrast highlights shadows whites blacks` -100…100 |
| `presence` | `texture clarity dehaze vibrance saturation` -100…100 |
| `colorMixer` | `subscript[ColorBand] -> HSLAdjustment {hue, saturation, luminance -100…100}`; bands `red orange yellow green aqua blue purple magenta`; JSON `{"bands":{"red":{…}}}`, default bands omitted |
| `effects` | `vignetteAmount` -100…100, `vignetteMidpoint` 0…100 (50), `vignetteRoundness` -100…100, `vignetteFeather` 0…100 (50), `grainAmount` 0…100, `grainSize` 0…100 (25), `grainRoughness` 0…100 (50) |
| `geometry` | `quarterTurns` 0…3 clockwise, `flipHorizontal`, `straightenAngle` -45…45° clockwise, `crop: NormRect` (full), `cropPresetID: Int64?`, `aspectLocked` |
| `masks: [Mask]` | `Mask {id, name, isEnabled, inverted, shape: MaskShape, adjustments: LocalAdjustments}` applied in order |

- `MaskShape`: `.linear(LinearGradientMask {start, end})` (full effect at start → none at end),
  `.radial(RadialGradientMask {center, radiusX (× source width), radiusY (× source height), rotation° clockwise, feather 0…100})`,
  `.brush(BrushMask {strokes: [BrushStroke {points, radius (× source width), feather, flow 0…100, isEraser}]})`.
  JSON: `{"kind":"radial","radial":{…}}`.
- `LocalAdjustments`: `temperature tint exposure contrast highlights shadows whites blacks texture clarity dehaze saturation`,
  all -100…100 except `exposure` -4…4 EV.
- Static ranges: `WhiteBalance.temperatureRange/tintRange`, `Tone.exposureRange/range`, `Presence.range`,
  `HSLAdjustment.range`, `Geometry.straightenRange`, `LocalAdjustments.exposureRange/range`.

### Coordinate systems

- `NormPoint` / `NormRect`: normalized 0…1, **origin TOP-LEFT, y down**.
- **source / mask space**: the oriented (EXIF applied), uncropped image. Masks live here (they are
  rendered before geometry, so they stick to the content when you crop/rotate).
- **frame / crop space**: after `quarterTurns` (clockwise), then `flipHorizontal` (mirror x of what
  you see), then `straightenAngle` (content rotated clockwise about the frame center; the frame keeps
  the rotated image's size, uncovered corners are empty). `geometry.crop` is normalized to this frame.
  Keeping the crop inside the rotated content is the crop tool's job.
- **cropped space**: normalized to the crop rect (final image).
- `GeometryMath(sourceSize:geometry:)` implements these maps (`framePixel(fromSource:)`,
  `sourcePixel(fromFrame:)`, `frameNormalized(fromSource:)`, `sourceNormalized(fromFrame:)`,
  `croppedNormalized(fromFrame:)`, `frameNormalized(fromCropped:)`, `frameSize`, `croppedSize`).
  GeometryStage MUST render exactly this mapping.

## Render pipeline (`Develop/RenderPipeline.swift`)

```swift
RenderPipeline.makeSource(url: URL, draft: Bool = false) -> RenderSource?     // caller has sandbox access
RenderPipeline.render(source:, settings:, targetSize: CGSize? = nil, draft: false, applyCrop: true) -> CIImage
RenderPipeline.renderCGImage(source:, settings:, targetSize:, draft:, applyCrop:, colorSpace: displayP3) -> CGImage?
RenderPipeline.renderCGImage(url:, settings:, maxPixelSize: Int?, colorSpace: displayP3) -> CGImage?
RenderPipeline.context            // shared Metal CIContext, working space extended linear sRGB, no intermediate cache
RenderPipeline.renderScale(source:settings:targetSize:applyCrop:) -> CGFloat
```

- `RenderSource` (`@unchecked Sendable`): `url`, `isRAW`, `rawFilter: CIRAWFilter?` (mutable — only
  touch while holding `source.lock`), `image` (non-RAW, oriented), `orientedSize` (full-res px),
  `asShotTemperature/asShotTint`. Keep one per open photo (DevelopSession does).
- RAW = `UTType.rawImage` by extension → `CIRAWFilter` (orientation applied by the filter);
  otherwise `CIImage(contentsOf:, .applyOrientationProperty)`.
- Color: working space **extended linear sRGB** (linear, may exceed 1). `renderCGImage` outputs 8-bit
  **Display P3** by default; pass `RenderPipeline.sRGB` for web export.
- `targetSize` is the pixel box the final (cropped) output should fit; the scale is applied at decode
  (`CIRAWFilter.scaleFactor` / Lanczos), so stages see a smaller image; never upscales.

Stage order (fixed), one file each in `Develop/Stages/`, all `nonisolated enum` with:

```swift
static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage
```

1. `RawDecodeStage.apply(source:settings:scale:draft:)` — decode, WB (asShot → camera neutral; custom →
   `neutralTemperature/neutralTint`; non-RAW: `CITemperatureAndTint` relative to 6500 K), exposure,
   scale; output extent `(0,0,W,H)`. **Implemented.**
2. `ToneStage` — contrast/highlights/shadows/whites/blacks (not exposure). **Implemented.**
3. `PresenceStage`. **Implemented.**  4. `ColorMixerStage`. **Implemented.**
5. `MaskStage` — for each enabled mask with non-zero adjustments: mask image from shape (white =
   effect, `Masking/MaskRenderer`), invert if needed, `LocalAdjustmentRenderer.apply(image, mask.adjustments,
   context:)`, blend with `CIBlendWithMask`; masks chain. **Implemented.**
6. `GeometryStage` — turns/flip/straighten/crop per GeometryMath; output extent at (0,0);
   when `!context.applyCrop` output the whole frame. **Implemented** (one affine transform; cropped
   output = round(full-res crop size × `requestedScale`) px, exact aspect ±1 px).
7. `EffectsStage` — post-crop vignette + grain relative to final extent. **Implemented.**

`LocalAdjustmentRenderer.apply(_ image: CIImage, _ adj: LocalAdjustments, context: RenderContext) -> CIImage`
(pass the stage's `context` through so eager intermediates use the right CIContext).

`RenderContext`: `fullSize` (full-res oriented px), `imageSize` (pre-geometry extent at render scale),
`scale` (multiply pixel radii by it), `draft`, `applyCrop`, `ciPoint(_ NormPoint) -> CGPoint`
(top-left normalized → CI bottom-left pixel coords of the pre-geometry image), `requestedScale`
(scale asked of the decoder; CIRAWFilter rounds sizes up, so it can differ slightly from `scale`).

## Develop engine: color spaces, kernels, interactive rendering

Color spaces each stage expects (all stage inputs/outputs: CI working space = **linear, extended-range
sRGB primaries**, extent `(0,0,W,H)`):

| Stage | Works in | Notes |
|---|---|---|
| RawDecodeStage | camera space → linear | CIRAWFilter: demosaic, WB, `exposure` + `baselineExposure` in **scene-linear** light, then its base tone curve (boost) → **display-referred linear** (1.0 = diffuse white, >1 = recovered highlights). Non-RAW: decoded to linear sRGB. |
| ToneStage | perceptual luminance P = Y^(1/2.2) | curve on P, applied back as a luminance ratio (hue kept); highlights/shadows from an edge-aware (guided-filter) base of P |
| PresenceStage | P (texture, clarity), linear (dehaze), Oklab (vibrance, saturation) | |
| ColorMixerStage | OkLCh | 8 band centers, smooth partition-of-unity falloff |
| MaskStage → LocalAdjustmentRenderer | same as the global stages (it reuses `AdjustmentOps`) | local temp/tint = luminance-preserving RGB gains, exposure = linear gain |
| EffectsStage | P | vignette on the final extent; grain seeded by `RenderContext.seed`, sized in full-res pixels |

- **Camera-matched baseline** (`Adjustments/BaselineExposure.swift`): CIRAWFilter's default render is
  much darker than the camera JPEG (Leica SL2: +0.45…+2 EV in the midtones). `makeSource` compares a tiny
  default decode with the embedded JPEG and stores `RenderSource.baselineOffset` (EV, clamped −1…+1.5,
  highlight-guarded), applied via `baselineExposure`. "No edits" now looks like the Library thumbnail.
- **Decode scale**: RawDecodeStage decodes at a scale where both dimensions are whole pixels (j / gcd(w,h))
  and Lanczos-resamples the remainder — CIRAWFilter otherwise adds a garbage edge row/column (bright line).
- **Kernels** (`Kernels/DevelopKernels.swift`): Metal CI color kernels compiled at runtime with
  `CIKernel.kernels(withMetalString:)` — no build flags. Compile each function from its own source
  string (CI resolves every kernel of a multi-function string to the same function).
- **Ops** (`Adjustments/AdjustmentOps.swift`): `tone`, `detail` (texture/clarity), `dehaze`,
  `vibranceSaturation`, `temperatureTint`, `exposure`, `edgeAwareBase` (fast guided filter), `materialize`.
  Radii are fractions of the long side ⇒ proxy, thumbnail and export look alike. Small blurred bases are
  rendered eagerly with `RenderContext.ciContext` (otherwise large tiled renders re-evaluate the whole
  graph per tile).
- **Pipeline additions**: `RenderPipeline.interactiveContext` (caches intermediates: a slider change
  re-renders a 60 MP DNG at 1600 px in ~5–15 ms), `render(…, proxyScale:, context:)`,
  `renderCGImage(…, proxyScale:, context:)`, `makeCGImage(_:colorSpace:context:)` (renders NOW, not
  deferred to draw time), `RenderContext.seed` / `.ciContext`, `RenderSource.seed/baselineOffset/defaultBaselineExposure`.
- **DevelopSession**: streaming changes (< 250 ms apart) render proxies (decode at canvas scale = cache hit,
  stages at ≤ 1600 px), a full-quality render follows 150 ms after the last change; one in flight, latest
  wins. Also `showBefore` (Photo > Before / After, `\`), `histogram`, `isPickingWhiteBalance`,
  `setWhiteBalance(from: .auto | .point(NormPoint))`, `copySettings()/pasteSettings()`
  (Photo > Copy/Paste Settings ⇧⌘C/⇧⌘V; excludes geometry and masks; Library paste = all selected).
- `DevelopSlider` gained `track: .plain | .gradient([Color])` (before `onEditingChanged`), an editable value
  field, ⌥-drag fine adjust, double-click title/track to reset. Existing call sites are unchanged.
- Harness: `Tools/develop_check.swift` (renders every control, invariants, scale consistency, timing).

## Masks (`Develop/Masking/*`, `Stages/MaskStage`, `Panels/MaskPanel`, `Overlays/MaskOverlayView`)

- Engine: `MaskRenderer` (shape → grayscale mask over the pre-geometry image; linear / radial
  gradients, brush via `BrushRasterizer` with an incremental cache), `MaskEditing` (brush point
  decimation, names, pins). Masks live in source space, so they stay on the content under crop/rotate.
- UI: `DevelopSession+Masks` (add / update / delete / select / `finishMasking`), `MaskToolState.shared`
  (pending creation kind, brush settings, overlay toggle), `MaskInteraction` (drag handling in source
  pixels via `MaskSpace` → `CanvasGeometry`), `MaskCoverageRenderer` (red overlay, off-main).
- Harness: `Tools/masks_check.swift`.

## Crop & rotate (`Develop/Crop/*`, `Stages/GeometryStage`, `Panels/CropPanel`, `Overlays/CropOverlayView`)

- `CropMath` (frame-pixel constraint math: crop always inside the rotated content; quarter-turn / flip
  of a whole `Geometry`), `DevelopSession+Crop` (tool session with snapshot for Esc, aspect choices
  `.original/.custom/.preset(id)`, straighten, rotate, swap, commit / cancel; one undo step each),
  `Catalog+CropPresets` (default seeding incl. 16:9, reorder), `CropPresetsEditor`, `CropKeyMonitor`.
- The canvas shows the uncropped frame while the crop tool is active (`applyCrop: false`).
- Harness: `Tools/crop_check.swift` (CropMath, GeometryStage vs GeometryMath marker image, DNG renders).

## DevelopSession (`Develop/DevelopSession.swift`, MainActor, `@Observable`)

Created by AppModel for the photo in Develop (`model.developSession`).

- `photo`, `catalog`, `source: RenderSource?`, `orientedSize`, `asShotTemperature/asShotTint`
- `settings: EditSettings` — mutate freely; each change → debounced save (300 ms, bumps edit_version),
  coalesced off-main re-render (one in flight, latest wins), undo step (changes within 0.6 s grouped).
- `renderedImage: CGImage?` (preview placeholder first, `isPlaceholder`), `renderedWithCrop`,
  `isLoading`, `loadError`
- `activeTool: DevelopTool (.none/.crop/.mask)` — `.crop` re-renders WITHOUT crop; `selectedMaskID: UUID?`
- `viewPixelSize` (set by the canvas), `requestRender()`
- `undo()`, `redo()`, `canUndo`, `canRedo`, `commitUndoGroup()` (call at drag end), `resetAll()`
- `saveNow()`, `close()` (AppModel calls on photo switch / leaving Develop)
- `canvasGeometry(imageRect:) -> CanvasGeometry`

## Canvas, overlays, CanvasGeometry

`DevelopCanvasView` draws `renderedImage` aspect-fit (16 pt margin) and computes `imageRect` in its own
coordinate space (top-left origin). Overlay slot:

```swift
switch session.activeTool {
case .crop: CropOverlayView(session: session, imageRect: rect)   // canvas shows the UNCROPPED frame
case .mask: MaskOverlayView(session: session, imageRect: rect)   // canvas shows the cropped image
case .none: Color.clear
}
```

Overlays are laid out over the whole canvas, so their local coordinates == canvas coordinates.
Convert with `let g = session.canvasGeometry(imageRect: imageRect)`:

- mask space: `g.viewPoint(fromMask: NormPoint)`, `g.maskPoint(fromView: CGPoint)`,
  `g.viewLength(fromSourceWidthFraction:)`, `g.sourceWidthFraction(fromViewLength:)`, `g.viewLength(fromSourceHeightFraction:)`
- crop/frame space: `g.viewPoint(fromFrame:)`, `g.framePoint(fromView:)`, `g.viewRect(fromFrame: NormRect)`
- displayed image: `g.viewPoint(fromDisplayed:)`, `g.displayedPoint(fromView:)`; `g.viewScale` = view pt per source px
- `CanvasGeometry.aspectFitRect(imageSize:in:)`

`showsCrop` comes from `session.renderedWithCrop` (the image actually on screen), so conversions
stay correct while a re-render is in flight. GeometryStage renders exactly GeometryMath (checked by
`crop_check`), so the mask overlay (pins, ellipse, red coverage) and the WB eyedropper
(`maskPoint(fromView:)` → oriented source point sampled by `WhiteBalanceEstimator`) stay aligned under
rotate / straighten / crop.

## Develop UI

- `DevelopInspectorView`: undo/redo/reset, tool picker, then panels in this order: WhiteBalance, Tone,
  Presence, ColorMixer, Effects, Crop, Mask (each `Panels/<Name>Panel.swift`, `@Bindable var session`).
- `InspectorSection(title, id:, onReset:) { … }` collapsible section; `PanelTODO` placeholder text.
- `DevelopSlider(title:value:range:defaultValue:scale:format:step:onEditingChanged:)` — double-click the
  label to reset; `.logarithmic` scale (Kelvin); formats `.integer/.signedInteger/.signedDecimal(n)/.kelvin/.custom`.
  Pass `onEditingChanged: { if !$0 { session.commitUndoGroup() } }`.
- Panels: WB (As Shot / Custom / Auto, eyedropper), Tone, Presence, Color Mixer, Effects, Crop
  (presets, straighten, rotate / flip, aspect lock, presets editor), Masks (linear / radial / brush,
  per-mask local adjustments, invert, overlay).

## Previews (`Previews/`)

```swift
enum PreviewLevel { case thumbnail /*512px default*/, standard /*2048px default*/; var maxPixelSize: Int } // from PreviewSettings
PreviewService.shared.configure(catalog:)                 // AppModel does this
func image(for: Photo, level: PreviewLevel) async -> CGImage?
func load(_ photo: Photo, level:, priority: .visible/.background) async -> PreviewResult // {image, isOffline}
func cachedImage(for: Photo, level: PreviewLevel) -> CGImage?   // memory hit only
func invalidate(photoID: Int64)                           // = discard(photoIDs: [id])
func discard(photoIDs:), discardAll(), purgeMemoryCache(), prefetch(_:level:)
func build(photoIDs: [Int64], levels: [PreviewLevel] = [.thumbnail, .standard], title: String? = nil) // any thread
func reloadSettings()                                     // after changing PreviewSettings.Keys in UserDefaults
static func embeddedThumbnail(url:maxPixelSize:) -> CGImage?
```

Memory (NSCache) → disk `<catalogDirectory>/Previews/<id&0xff hex>/<id>_<t|s>_v<edit_version>_<size>q<quality><e|r>.jpg`
→ generate. Key includes edit_version + size/quality/source, so edits and settings changes make
previews stale (lazy regen; thumbnails of edited photos are also regenerated eagerly, 1 s after the
last `.photosUpdated`). Unedited: embedded camera JPEG (≈20 ms per Leica DNG); edited: `RenderPipeline`.
Work runs on prioritized, coalesced, cancellable `PreviewLane`s. Offline originals fall back to any
cached version (`isOffline`). LRU pruning by file modification date to the configured max size.
`PreviewJobs.shared` (@Observable): build jobs progress (`current/done/total/cancel()`) and per-photo
revisions. UI: `Previews/UI/` — `PreviewSettingsView` (Settings > Previews tab, and the `.previewSettings`
sheet), `PreviewCommands` (Library > Previews ▸), `PreviewActivityView` (main window toolbar; empty
when idle). Importers queue thumbnails with `build(photoIDs:levels: [.thumbnail])`. Offline
originals are remembered and retried when roots change (see Change notifications). `Library/ThumbnailView` is the only view that loads previews (grid + filmstrip).

## Import

- `PhotoMetadataReader.read(url:) -> PhotoMetadata?` (dims, orientation, capture date with EXIF offset /
  subseconds, make/model/lens, ISO, shutter, aperture, focal length, file size, UTI, plus the raw
  capture fields `captureDateTime/captureSubsec/captureOffset`), `isRAW(url:)`, `isSupportedImage(url:)`,
  `rawExtensions`, `imageExtensions`.
- **RAW + JPEG capture time**: Leica DNGs have no OffsetTimeOriginal while the paired JPEG has one
  (+02:00), so the RAW was read in the local zone (1 h off here). `read(url:sidecar:)` and
  `adoptSidecarOffsets(_:)` (used by `ImportScanner.readMetadata`) re-read a RAW's wall-clock time with
  its sidecar's offset when the RAW has none and the wall-clock times match.
- `Photo(url:metadata:importDate:sidecarPath:)` builds an insertable photo.
- SD card / folder import (`Import/`): `ImportScanner` (enumerate, RAW+JPEG pairing, metadata),
  `DuplicateIndex`, `ImportJob.run` (Copy to Destination with safe copy into date folders, or Add in
  Place; one import date; optional new folder) → `ImportJob.warmPreviews` queues a thumbnail build job.
  Copying needs write access to the destination (read/write user-selected-files entitlement, or the
  container).
- Lightroom Classic import (`LightroomImport/`): `LightroomCatalogReader.load(copying:)` (reads a temp
  copy), `LightroomImportPlan` (collection sets + collections → folders under a "Lightroom" folder,
  virtual copies → master), `Catalog.importLightroom` (idempotent: re-import adds nothing), roots
  without bookmarks (grant access later: Settings > Drives / the import sheet).
- `DevTools.addPhotos(under:catalog:)` is a reference in-place importer (RAW+JPG pairing → sidecar).

## Export (`Export/`)

- Engine (`ExportEngine.swift`, UI-free, harness `Tools/export_check.swift`):
  `ExportJob(catalog:photoIDs:options: ExportOptions(destination:quality:), settingsOverride:)`,
  `run(progress:) -> ExportResult` (synchronous, call off-main; `cancel()` from anywhere). Per photo:
  `SecurityScopeManager.accessibleURL` → full-resolution `RenderPipeline.renderCGImage(…, colorSpace: sRGB)`
  with the saved `EditSettings` (8-bit sRGB) → ImageIO JPEG (`LossyCompressionQuality = quality / 100`).
  At most `maxConcurrentRenders` (2) renders at once, one `autoreleasepool` per photo. A photo whose
  render finishes after `cancel()` is dropped (never half-written).
- Metadata (`ExportMetadata`): EXIF (dates, exposure, lens), ExifAux, GPS, IPTC, TIFF make/model/date
  from the original; Orientation 1, EXIF pixel size = output, ColorSpace sRGB, Software "Sloproom";
  no thumbnail, no CFA/DNG fields. RAWs without `OffsetTime*` take them from the sidecar JPEG when
  the capture wall-clock time matches (Leica).
- Files (`ExportFiles`): name = original base name + `.jpg`, `-1`, `-2`… for names that exist or
  are claimed by the same job; written to a hidden `.sloproom-export-*.jpg.tmp` in the destination
  (exclusive create + fsync), then `renamex_np(RENAME_EXCL)`. `checkWriteAccess` = probe file:
  `ExportError.noWriteAccess` → "Sloproom doesn't have write access to “…”. Enable User Selected
  File: Read/Write in Signing & Capabilities." (stops the job), `.unavailable` for a missing folder.
  Offline / unreadable / failed photos are skipped and listed (`ExportResult.skipped`, `summary`).
- UI (`Export/UI/`): `ExportController.shared` (@Observable; destination remembered as a
  security-scoped bookmark `export.destinationBookmark` + `export.destinationPath`, write-probed
  off-main when chosen/restored; `export.quality` default 85). `ExportSheet`: destination row +
  Choose… (NSOpenPanel), quality slider, Export / Cancel; progress "Exporting 3 of 12…"; summary +
  Show in Finder. Entry points: File > Export… (⇧⌘E, `ExportCommands`, disabled via the
  `exportTargetCount` focused scene value, targets read on invocation), grid context menu
  `ExportMenuButton` ("Export N Photos…"), `.exportSheet(model:)` on the main window. In Develop the
  current photo is exported with the session's live settings (its catalog save is async).
