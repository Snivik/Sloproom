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
| `App/sloproomApp.swift` | scene: main `Window` (+ `SloproomCommands`, `PreviewCommands`, …), `Settings` (`SettingsRootView`: tabs Previews, Drives, Keyboard) |
| `App/AppModel.swift`, `FolderTree.swift`, `SloproomCommands.swift` | app state, folder tree, menu bar (+ `TextInputGuard`) |
| `App/DevTools.swift`, `App/IntegrationDevScript.swift` | "Add Folder in Place (Dev)", `DevScript` (DEBUG UI scripting); feature DevScript files live next to their feature |
| `Catalog/*` | SQLite wrapper, catalog open/migrate, photos / folders / roots / crop-preset API, models, security scope |
| `Import/*` | SD card / folder import: engine (`ImportEngine`), sheet state (`ImportSession`), sources, sheet UI, EXIF reader (`PhotoMetadataReader`) |
| `LightroomImport/*` | Lightroom Classic catalog import (structure only), root access status / grants (`RootAccess`, `RootsAccessView`) |
| `Library/*` | main window, grid, cells, filmstrip, sidebar; `ThumbnailView` (the only preview loader) |
| `Library/Sidebar/*` | folder management (create/rename/delete/move/reorder, DnD, context menus), sidebar state, folders DevScript (key/click synthesis) |
| `Library/Flags/*` | flag actions (auto-advance), grid filter bar, `LibraryKeyMonitor` (installs the shortcut dispatcher; D, ⌘A) |
| `Previews/*` (+ `Previews/UI/*`) | preview service, disk cache, lanes, build jobs, settings, recent Develop renders + neighbour prefetch (+ settings view, Library > Previews menu, toolbar activity, `rr` DevScript) |
| `Develop/EditSettings.swift`, `GeometryMath.swift`, `CanvasGeometry.swift`, `RenderPipeline.swift` | edit model, geometry maps, render pipeline |
| `Develop/Stages/*` | the 7 render stages + `LocalAdjustmentRenderer` |
| `Develop/Adjustments/*`, `Develop/Kernels/*` | adjustment ops, Metal CI kernels, histogram, WB estimator, baseline exposure; `Adjustments/UI/*` clipboard, WB picker, histogram view, DevScript |
| `Develop/Masking/*` (+ `Masking/UI/*`) | mask rasterization (engine) + mask tool state/interaction/coverage overlay |
| `Develop/Crop/*` | crop math, crop actions on `DevelopSession`, preset catalog API + editor, `CropKeyMonitor` |
| `Develop/DevelopSession.swift`, `DevelopView/Canvas/Inspector`, `DevelopSlider`, `Panels/*`, `Overlays/*` | develop session + UI |
| `Develop/Zoom/*` | canvas zoom / pan (`ZoomController`, `RegionRenderer` engine; free-form pinch, smart magnify), view bar, panel + folder sidebar visibility (Tab / ⇧Tab / ⌃⌘S, per mode), full-screen preview (F), DevScript |
| `Export/ExportEngine.swift` (+ `Export/UI/*`) | JPEG export engine (+ sheet, controller, File > Export… / context menu, DevScript) |
| `Shortcuts/*` | keyboard shortcut registry (`ShortcutModel`, `ShortcutStore`), dispatcher + menu items (`ShortcutKeys`), Settings > Keyboard, tooltip helpers (`SegmentHelp`), DevScript |
| `CatalogTransfer/*` | Export Catalog / Import Catalog (engine `CatalogTransfer.swift`; controller, sheet + `CatalogTransferCommands`, DevScript) |

Conventions: new catalog API as `nonisolated extension Catalog` in the feature's own
`Catalog+Feature.swift`; feature tables via `applyMigration(named:sql:)`; engine files (anything
a harness compiles) import no SwiftUI/AppKit and mark types `nonisolated`.

## Catalog

`nonisolated final class Catalog: @unchecked Sendable`. All methods are synchronous, thread-safe
(one recursive lock in `SQLiteDatabase`) and `throws`. Call heavy ones off the main thread.

- **Owner decision (frozen): edits live ONLY in the catalog — no XMP / sidecar files are ever
  written. Portability between Macs is File > Export Catalog… / Import Catalog… (see below).**
- Location: `Catalog.defaultDirectory` = `<Application Support>/Sloproom` (inside the container when
  sandboxed; `SLOPROOM_CATALOG_DIR` env overrides). `catalogDirectory` holds `Catalog.sqlite`;
  `cacheDirectory("Previews")` returns/creates a subdirectory for caches.
- Open: `Catalog.openDefault()`, `Catalog.open(at: URL)` (harnesses: temp dir).
- Schema: `PRAGMA user_version` migrations in `Catalog.migrations` (append-only, foundation-owned);
  `Catalog.schemaVersion` = the version this app writes (Import Catalog refuses newer files).
- Lifecycle: `catalog.close()` / `db.close()` close the connection (later calls throw "database is
  closed"); only Import Catalog uses it, followed by `AppModel.replaceCatalog(with:)`.
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

## Catalog transfer (`CatalogTransfer/`, harness `Tools/catalog_transfer_check.swift`)

- **Export** (`CatalogTransfer.exportCatalog(_:to:appVersion:appBuild:sourceMac:)`, off-main):
  `VACUUM INTO <catalogDir>/Transfer/export-<uuid>.sqlite` (consistent while the app writes), then
  in the SNAPSHOT only: table `catalog_info(key, value)` (`format`, `format_version` =
  `CatalogTransfer.formatVersion` (1), `app_version`, `app_build`, `schema_version`, `exported_at` (ISO
  8601) + `exported_at_unix`, `source_mac` (`Host.current().localizedName`), `export_id`, `photo_count`,
  `edited_photo_count`, `folder_count`, `root_count`), `journal_mode=DELETE` (one self-contained file),
  `integrity_check` + `foreign_key_check`, then placed at the destination: safe-save via an item
  replacement directory, else hidden sibling + `rename`, else a direct write (a sandboxed save-panel
  grant may cover only the chosen file). Default name `Sloproom Catalog YYYY-MM-DD.sloproomcatalog`.
  Previews are NOT included. Pending Develop edits are flushed first (`DevelopSession.flushPendingSaves()`).
- **Import** (`stageImport(from:stagingDirectory:)`): copies the picked `.sloproomcatalog` / `Catalog.sqlite`
  (+ its `-wal` if readable; warning otherwise) into `<catalogDir>/Transfer/`, never opens it in place.
  `validate`: required tables (`photos folders folder_photos roots applied_migrations`), photos columns,
  `user_version` 1…`Catalog.schemaVersion` (newer → `.newerSchema`, clear message), `format_version` ≤ 1,
  `integrity_check`, FK check. Summary sheet: photos / edited / flags / folders / exported at + Mac /
  app version / schema, drives with `RootAccess.status`, Cancel / Replace Current Catalog.
- **Replace** (in-process, no relaunch — `CatalogTransferController.replace`): `model.prepareForCatalogReplacement()`
  (Library, no selection, empty grid), cancel preview jobs, flush Develop saves, wait 0.8 s for in-flight
  preview loads, then off-main `CatalogTransfer.replaceCatalog`: backup `VACUUM INTO
  <catalogDir>/Backups/Catalog-YYYYMMDD-HHMMSS.sqlite` (newest 10 kept), `close()`, remove `-wal/-shm`,
  atomic rename of the staged file to `Catalog.sqlite`, `Catalog.open` (older schemas migrate), count
  check; any failure after closing restores the backup and reopens it (`.replaceFailed(…, reopened:)`).
  On main: `SecurityScopeManager.shared.reset()` (scopes are cached per root id), Previews directory
  moved aside + deleted in the background and `PreviewService.discardAll()` (previews are keyed by photo
  id), `model.replaceCatalog(with:)` (reconfigures `PreviewService`, observer, source All, reload). The
  sidebar is keyed by `ObjectIdentifier(model.catalog)` so its counts object restarts. The result sheet
  names the backup and, if any root isn't `.granted`, embeds `RootsAccessView` with instructions.
- **Relink** (`RootAccess.relink(_:to:bookmark:catalog:)`, engine in `RootAccess.swift`):
  `catalog.relinkCheck(root:newPath:)` samples ≤ 200 of the root's photos (those under it and not under a
  more specific root) at the same relative paths (UI warns below 80%, "Relink Anyway");
  `catalog.relinkRoot(id:to:bookmark:displayName:)` rewrites `roots.path` + bookmark and every photo
  `path` / `sidecar_path` under the old prefix (`Catalog.normalizedPath`, `Catalog.relinkedPath`) in one
  transaction (refuses a path that is another root or would collide with existing photos), posts
  `.roots`. `RootsAccessView` ("Relink…" next to Grant Access, also in Settings > Drives) runs it
  off-main, then `model.reloadPhotos()` + `PreviewJobs.notifyChanged(ids)` so thumbnails that were
  offline retry with the new paths.

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

Menus (`SloproomCommands` + `PreviewCommands` + `ExportCommands` + `CatalogTransferCommands`): File > New Folder, Import Photos…,
Import Lightroom Catalog…, Add Folder in Place (Dev)…, Export…, Export Catalog…, Import Catalog…; Edit > Undo/Redo route to the develop session
in Develop mode, otherwise to the responder chain; Edit > Select All Photos; Photo > Pick, Unflag, Reject, Auto Advance After Flagging,
Set Rating (0–5), Copy / Paste Settings, Before / After; View > Library, Develop, Show / Hide Folders, Keyboard Shortcuts…; Library > Previews ▸ (build /
regenerate / discard for selection, build all, clean cache); Help > Keyboard Shortcuts…. Every item with a shortcut is a
`ShortcutMenuButton` (keys: see the registry below). Menu items that act on the selection read
`model.actionTargetIDs` when chosen (menu-bar Commands are not re-rendered on selection changes, so
don't compute `.disabled` from the selection there).

The toolbar flag-filter menu is shown only in Develop (it filters the filmstrip); Library uses the
`GridFilterBar` (same `model.filter`).

### Keyboard shortcuts (`Shortcuts/`, harness `Tools/shortcuts_check.swift`)

Every shortcut is a **registry action**; the user can rebind any of them in Settings > Keyboard (also
View / Help > Keyboard Shortcuts…). Never hard-code a key in a handler or a tooltip: add a
`ShortcutAction` and read the binding.

- `ShortcutModel.swift` (UI-free): `KeyCombo` (key + `KeyModifiers`; spec strings `"cmd+shift+e"`, `"k"`,
  `"escape"`; `display` "⇧⌘E"; `accepts(_:)`: ⌘= / ⌘- also fire with ⇧ (⌘+ / ⌘_), ⌫ accepts ⌦, grid arrows
  accept an extra ⇧), `ShortcutContext` (the ONE state a key arrives in: `library`, `develop`, `crop`,
  `mask`, `whiteBalance` (eyedropper armed), `fullScreen`), `ShortcutScope` (a set of contexts: Everywhere,
  Library & Develop, Library, Develop (incl. its tools), Develop & Full Screen, Crop Tool, Mask Tool, White
  Balance Selector, Full Screen Preview), `ShortcutAction` (stable string id = persisted, title, category,
  scope, default binding, `repeats`, `isMenuCommand`, `focusGroup`).
- Scopes: the same key may mean different things in scopes that don't overlap (⌘= = thumbnail size in
  Library, zoom in Develop / full screen); a **narrower scope overrides a broader one** (X = Swap Aspect in
  the crop tool overrides X = Reject everywhere). Two bindings **conflict** only when their scopes overlap
  and neither is strictly narrower (both Everywhere; Library & Develop vs Develop & Full Screen), and not
  when they're focus-exclusive (grid vs sidebar ⌫).
- `ShortcutStore.shared` (@Observable): defaults + overrides in UserDefaults `shortcuts.overrides`
  ([id: spec], "" = none) and `shortcuts.revision` (bumped per change), `binding(for:)`, `setBinding`,
  `reassign` (takes the key from conflicting actions), `reset`, `resetAll`, `conflicts(for:action:)`,
  `overridden(by:)`, `candidates(for:in:)` (narrowest scope first), `help("Pick", .pick)` → "Pick (P)".
- `ShortcutKeys.swift`: `KeyCombo(event:)` (special keys by key code, printable keys = character without
  modifiers), `ShortcutMenuButton` / `ShortcutMenuToggle` (menu item with the user's key;
  `TextInputGuard.forwardIfTyping` types plain keys into a focused text field instead),
  `ShortcutMenuSync` (SwiftUI never updates an existing NSMenuItem's key equivalent, so after a change the
  registry items are patched by title), `ShortcutDispatcher` (**one** local keyDown/keyUp monitor, installed
  by `MainWindowView.libraryKeyShortcuts`): computes the context of the key window (main window or the
  full-screen window; nil while a text field is edited, a sheet is up, or another window such as Settings is
  key), asks the store for candidates and performs the first one whose registered handler is available; if
  the first match is a menu command without handler it lets the menu take the key. A ⇧ key press with no
  candidates is retried as the character it typed without ⇧ (`KeyCombo.shiftedAlternative`: German ⇧⌘0 = "⌘="),
  and `lastDispatch` also records "no available handler" (an unhandled key ends in NSBeep). Non-repeating actions
  swallow auto-repeats (holding X in crop never falls through to Reject). Views register handlers with
  `.shortcutHandlers(id:) { [ShortcutHandler(.action, when: { event in … }) { event in … }] }`
  (re-registered when `id` changes, removed on disappear); `release:` = key-up of held keys (Space).
- Tooltips: `.help("Rotate Left", shortcut: .rotateLeft)` / `.iconHelp(…)` (+ accessibility label) compute
  the text from the store, so tooltips follow rebinding. Segmented pickers: `.segmentHelp([...])` (per-segment
  tooltips on the NSSegmentedControl; SwiftUI's `.help` never reaches segments). Window toolbar items:
  `.toolbarHelp([label: tip])` (SwiftUI doesn't pass `.help` to NSToolbarItems). Audit:
  `Tools/ax_help_audit.swift` (see Tools/README).
- `KeyboardSettingsView.swift`: Settings > Keyboard (search, record: Esc cancels, ⌫ removes, conflict →
  "Already used by …" Reassign / Cancel, per-row reset, Reset All; ⌘Q / ⌘W / ⌘H / ⌘M / ⌘, / ⌘` refused).
  `SettingsNavigation.shared.tab` selects the Settings tab.

#### Keyboard map (defaults)

| Action (id) | Default | Scope | Handler (file) |
|---|---|---|---|
| New Folder (`newFolder`), Import Photos… (`importPhotos`), Export… (`exportPhotos`) | ⇧⌘N, ⇧⌘I, ⇧⌘E | Everywhere | menu (`SloproomCommands`, `ExportCommands`) |
| Import Lightroom Catalog…, Export Catalog…, Import Catalog…, Auto Advance After Flagging, Keyboard Shortcuts… | none (assignable) | Everywhere | menu (`SloproomCommands`, `CatalogTransferSheet`, `FlagActions`, `KeyboardSettingsView`) |
| Undo / Redo | ⌘Z / ⇧⌘Z | Everywhere | menu (Develop → session, else responder chain) |
| Pick / Unflag / Reject | P / U / X | Everywhere | menu (`SloproomCommands` → `FlagActions`) |
| Rating None…★★★★★ (`rating0`–`rating5`) | 0–5 | Everywhere | menu |
| Copy / Paste Settings, Before / After | ⇧⌘C / ⇧⌘V, `\` | Everywhere | menu |
| Library (`libraryMode`) | G | Everywhere | menu |
| Develop (`developMode`) | D | Everywhere | menu + dispatcher handler (AppKit's Start Dictation takes plain D) — `LibraryKeyMonitor` |
| Select All Photos (`selectAllPhotos`) | ⌘A (was ⌥⌘A in the menu) | Library & Develop | dispatcher (`LibraryKeyMonitor`); the menu item shows no key (SwiftUI drops the duplicate of Edit > Select All) |
| Full Screen Preview (`fullScreenPreview`) | F | Everywhere (opens from the main window, closes in full screen) | `FullScreenShortcut` (FullScreenPreview.swift) + `FullScreenPreview.installKeys` |
| Close Full Screen Preview (`exitFullScreen`) | Esc | Full Screen | `FullScreenPreview.installKeys` |
| Previous / Next Photo | ← / → | Develop & Full Screen | `DevelopCanvasView` (not while the sidebar list has focus), `FullScreenPreview` |
| Zoom Fit ↔ 1:1 at the pointer, Zoom In, Zoom Out (next / previous preset, also from a free pinch level) | Z, ⌘= (⌘+), ⌘- (⌘_) | Develop & Full Screen | `ZoomEventMonitor` (handlers per ZoomController / window) |
| Zoom to Fit (`zoomFit`) | ⌘0 | Develop & Full Screen | `ZoomEventMonitor` |
| Show / Hide Folders (`toggleSidebar`) | ⌃⌘S | Everywhere (menu View > Show / Hide Folders; the toolbar sidebar button and the view bar button do the same) | menu (`SloproomCommands` → `DevelopPanels.toggleSidebar(in:)`, per mode) |
| Hand Tool (hold) (`temporaryHand`) | Space | Develop & Full Screen | `ZoomEventMonitor` (key-up releases) |
| Show / Hide Side Panels, All Panels | Tab, ⇧Tab | Develop | `DevelopPanels` (`developPanelShortcuts`) |
| Increase / Decrease Thumbnail Size | ⌘= (⌘+) / ⌘- (step 20 pt of the 100…400 slider) | Library | `LibraryGridView` |
| Select Previous / Next Photo, Photo Above / Below (`moveLeft/Right/Up/Down`) | ← → ↑ ↓ (⇧ extends) | Library, grid focused | `LibraryGridView` |
| Open in Develop | Return | Library, grid focused | `LibraryGridView` |
| Remove from Folder / Catalog (`removePhotos`) | ⌫ (⌦) | Library, grid focused | `LibraryGridView` (catalog removal asks first) |
| Delete Folder (sidebar) (`deleteFolder`) | ⌫ | Library & Develop, sidebar list focused | `SidebarView` (asks first) |
| Crop Tool (`toggleCropTool`), Rotate Left / Right | R, ⌘[ / ⌘] | Develop | `CropKeyMonitor` (`cropKeyboardShortcuts`, installed by `CropPanel`) |
| Swap Portrait / Landscape, Cycle Grid Overlay, Done (Keep Crop), Cancel Crop | X, O, Return (keypad Enter), Esc | Crop Tool | `CropKeyMonitor` |
| Show / Hide Mask Overlay, Decrease / Increase Brush Size, Delete Selected Mask, Cancel Mask / Leave Mask Tool | O, [ / ], ⌫ (⌦), Esc | Mask Tool | `MaskOverlayView` |
| Cancel White Balance Selector (`cancelWhiteBalance`) | Esc | WB selector armed | `WhiteBalancePickerOverlay` |

Not in the registry (standard controls): Return / Esc of sheet default / cancel buttons (`.keyboardShortcut(.defaultAction/.cancelAction)`),
text-field editing keys, sidebar list navigation, the system menu items (⌘Q, ⌘W, ⌘,, the hidden Toggle Sidebar ⌥⌘S…),
pinch (free-form) / two-finger double tap (smart magnify: Fit ↔ 100 %) / ⌘- or ⌥-scroll zoom and scroll panning
(`ZoomEventMonitor`'s scroll / magnify / smartMagnify monitor), mouse (click = zoom toggle, drag = pan).

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
- **Pipeline additions**: `RenderPipeline.applyStages(_:settings:context:)` (stages 2–7, used by `render` and zoomed region renders), `RenderPipeline.interactiveContext` (caches intermediates: a slider change
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
  (pending creation kind, brush settings, overlay toggle; **brush size is a screen size**: cursor radius
  `brushSize × 2.5` pt at any zoom, each new stroke stores `brushRadius(in: geometry)` = that screen radius
  in image-width units at the zoom it was painted, so zoomed-in strokes are finer; stored strokes unchanged), `MaskInteraction` (drag handling in source
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
`imageRect` is where the WHOLE displayed image is drawn — when zoomed it is larger than the canvas
and may start at negative coordinates — so every conversion below stays exact at any zoom / pan.
Convert with `let g = session.canvasGeometry(imageRect: imageRect)`:

- mask space: `g.viewPoint(fromMask: NormPoint)`, `g.maskPoint(fromView: CGPoint)`,
  `g.viewLength(fromSourceWidthFraction:)`, `g.sourceWidthFraction(fromViewLength:)`, `g.viewLength(fromSourceHeightFraction:)`
- crop/frame space: `g.viewPoint(fromFrame:)`, `g.framePoint(fromView:)`, `g.viewRect(fromFrame: NormRect)`
- displayed image: `g.viewPoint(fromDisplayed:)`, `g.displayedPoint(fromView:)`; `g.viewScale` = view pt per source px
- `CanvasGeometry.aspectFitRect(imageSize:in:)`
- zoom / pan: `CanvasViewport` (same file, pure math): `canvasSize`, `displayedSize` (source px),
  `displayScale`, `margin`, `level: ZoomLevel (.fit/.fill/.ratio(r), r = device px per image px)`,
  `center` (displayed-normalized point at the view center) → `imageRect` (clamped: the image can't
  leave the view), `visibleDisplayedRect`, `zoomed(to:anchor:)`, `zoomed(to:placing:at:)` (put a given
  displayed point under a view point), `panned(by:)`, `magnified(by:anchor:holding:)` (`holding` = a pinch's
  starting point, so the anchor doesn't drift while the image is still centered), `stepped(in:)`.
  `ZoomLevel.steps` = 25 / 50 / 100 / 200 / 400 / 800 % (`maxRatio` 8).

### Zoom, panels, full screen (`Develop/Zoom/`)

- `ZoomController` (@Observable; `.develop` shared across photos, the full-screen preview has its
  own): viewport + actions (`toggle(at:)`, `step`, `pan`, `magnify(by:anchor:phase:)`, `smartMagnify(at:)`,
  `zoomToFit()`, `setLevel`), locked to Fit while the crop tool is active. The canvas shows the fit render
  scaled immediately; ~100 ms after the view settles (settings changes: at once) `RegionRenderer` renders
  only the visible region (+96 px) at `min(1, pixelRatio)` and `tile` is drawn over it. The old tile stays
  up (scaled) during edits / zooming until the new one replaces it, unless the geometry changed.
  `window` is only ever set by the canvas (never cleared: on a photo switch the old canvas leaves the
  window after the new one joined it — clearing it killed ⌘= / Z / pinch after the first photo change).
- Trackpad pinch = free-form zoom Fit … 800 % (pinching out past Fit snaps to Fit), anchored at the
  fingers (the point under them at `began` is held). Per event only `viewport` changes (≈ 0.05 ms in the
  handler, ≈ 5–7 ms main-thread frame incl. SwiftUI update + commit on a 60 MP DNG); the region render
  waits for a 150 ms pause and starts at once on `ended` (≈ 35–60 ms later the sharp tile is up).
  `stats` (DevScript `zoomstats`) records handler / frame / sharp-after-end times (`FrameCostProbe`).
  Two-finger double tap (`.smartMagnify`) = Fit ↔ 100 % at the pointer. The full-screen preview shares
  `ZoomEventMonitor`, so all of this works there too.
- `RegionRenderer` (engine, harness `Tools/zoom_check.swift`): builds the graph at the zoom scale and
  crops the output to the region before rendering (CIRAWFilter is ROI-aware: 1:1 2800×1672 px of a
  60 MP DNG ≈ 20–30 ms). Settings with neighbourhood ops (highlights/shadows/clarity/dehaze, local
  masks with them) need the whole image for their blurred bases, so the stage-1 decode is materialized
  once (RGBAh, ≈ 375 MB at 1:1 for 60 MP; one cached, keyed by source/scale/WB/exposure; ≈ 300 ms)
  and region renders then take ≈ 40–50 ms. Uses `RenderPipeline.applyStages` (stages 2–7 on a decode).
- Canvas layers: image + tile, `HandToolLayer` (tool none: click = zoom toggle, drag = pan), tool
  overlay, WB eyedropper, space-bar `HandToolLayer` (over every tool but crop), `ZoomNavigator`
  (mini map while zoomed), `ZoomHUD`. `DevelopViewBar` (under the canvas): Fit / Fill / 1:1 (+ a
  selected "200%"-style preset segment or "Custom" for a free level) + level menu with the current %
  ("137%", fixed width so pinch frames don't re-lay out the column), panel toggles, full-screen button.
- `DevelopPanels.shared`: `sidebarHidden/inspectorHidden/filmstripHidden` (Develop) and
  `librarySidebarHidden` (per app session; the folder sidebar is remembered PER MODE).
  `columnVisibility(model:)` is MainWindowView's NavigationSplitView binding: it reads `model.mode` when
  called (SwiftUI keeps the binding its toolbar toggle was created with — a binding capturing the mode
  wrote Develop's toggles into the Library state, so the toolbar button did nothing in Develop);
  MainWindowView reads `isSidebarHidden(in:)` in its body so changes re-render. `toggleSidebar(in:)` =
  View > Show / Hide Folders (⌃⌘S), toolbar button, view bar button.
  The inspector stays in the hierarchy at zero width while hidden (its panels install key monitors).
- `FullScreenPreview.shared`: borderless window over the main window's screen (menu bar + Dock hidden
  unless the main window is in native full screen), black, standard preview first then a render at
  screen pixels (≈ 65–110 ms for a 60 MP DNG), next photo pre-rendered; live session settings when it
  shows the Develop photo.

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

Memory: one NSCache per level (thumbnails ≤ 768 MB, standard ≤ 512 MB, scaled down on machines
with < 48 GB RAM), so standard previews never push the grid's thumbnails out; ~1,000 thumbnails
stay decoded (scrolling back shows no placeholders). `PreviewService.stats` / `resetStats()` count
disk reads / generations per level (DevScript `rr stats`).

### Recent Develop renders (`Previews/RecentRenders*.swift`)

`RecentRenders.shared` keeps the last N full-quality Develop renders (Settings > Previews >
Develop "Keep last rendered photos", `previews.recentRenderCount`, default 100, 0 = off):
`<catalogDirectory>/Previews/Recent/<id>_<settingsHash>_<boxW>x<boxH>.jpg` (JPEG q 0.9, Display P3,
at canvas size, ≤ 3200 px) + an LRU of ≤ 16 decoded images / 400 MB. Key = photo id + FNV hash of
(EditSettings JSON, build signature) + the canvas pixel box; one file per photo; LRU by file date;
`Recent/.build` marks the build (another build deletes all). Excluded from the preview cache's
size/pruning; removed by Clean Cache (`discardAll`) and `discard(photoIDs:)`; stale renders of photos
edited elsewhere are dropped after `.photosUpdated`. `purgeAll()` resets all in-memory state
(memory, pending writes, index, prefetch) for an in-process catalog replacement.

- `DevelopSession` hook: on open it shows the recent render of the current settings instantly
  (memory, else disk off-main ≈ 5–10 ms), `imageOrigin == .recent`; if it was rendered at the current
  canvas size the first pipeline render is skipped (`renderedKey` set). Every final crop-applied
  render of the current settings is stored (memory now, disk write coalesced ~0.5 s).
- `RecentRendersPrefetch.shared.developOpened(index:in:)` (called by `AppModel.openDevelopSession`):
  next / previous / next-but-one photo → recent render into memory, else standard preview; the
  next photo's RAW is read ahead (background QoS) into the OS file cache.

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
