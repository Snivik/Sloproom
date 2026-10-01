# Tools

The app is sandboxed, so engine code (catalog, metadata, pipeline, previews) is tested with
headless CLI harnesses compiled straight from the app sources with `swiftc`.

## harness.sh

```sh
Tools/harness.sh <output-binary> <main.swift> [extra .swift files...]
```

- Compiles `<main.swift>` + the default engine file set + extra files with the same Swift settings
  as the app target: `-swift-version 5 -default-isolation=MainActor`, approachable concurrency
  upcoming features, `MemberImportVisibility`, `-parse-as-library`.
- `<main.swift>` must declare `@main struct X { static func main() async throws { ... } }`.
- Default engine set: `Catalog/*`, `Develop/EditSettings.swift`, `Develop/GeometryMath.swift`,
  `Develop/CanvasGeometry.swift`, `Develop/RenderPipeline.swift`, `Develop/Stages/*`, `Develop/Masking/*` (not `Masking/UI/`),
  `Import/PhotoMetadataReader.swift`, `Previews/*.swift` (not `Previews/UI/`).
  Engine files must not import SwiftUI/AppKit and must mark types `nonisolated`.
- Duplicated paths are ignored. `HARNESS_NO_DEFAULT=1` = only the files you pass.
  `HARNESS_OPT=-Onone` for faster compiles.
- The CLI is not sandboxed, so it can read sample files directly. Treat
  `/Users/snivik/Pictures` as READ-ONLY and write output under `/private/tmp/claude-501/<you>-out/`.
- Open catalogs with `Catalog.open(at: tempDir)`; never touch the app's real catalog.

## foundation_check.swift

Smoke test of the whole engine layer (catalog CRUD, folders, filters, EditSettings JSON,
GeometryMath, RAW + JPEG render, previews):

```sh
Tools/harness.sh /private/tmp/claude-501/foundation-out/foundation_check Tools/foundation_check.swift
/private/tmp/claude-501/foundation-out/foundation_check [photo-dir] [out-dir]
```

It writes `render_*.jpg` into out-dir; look at them with an image viewer (or Claude's Read tool).

## populate_catalog.swift + running the (sandboxed) app with real photos

Never build with the sandbox disabled (no `ENABLE_APP_SANDBOX=NO` overrides). Instead put the test
catalog AND the test photos inside the app's own container, which the sandboxed app can read/write:

```sh
C=~/Library/Containers/dev.snivik.sloproom/Data/tmp/<you>   # your private dir inside the container
mkdir -p $C/photos && cp /Users/snivik/Pictures/2026/2026-08-01/L10902{28,29,30}.DNG $C/photos/   # COPY, never move
Tools/harness.sh /private/tmp/claude-501/<you>/populate_catalog Tools/populate_catalog.swift
/private/tmp/claude-501/<you>/populate_catalog $C/cat $C/photos

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project sloproom.xcodeproj \
  -scheme sloproom -configuration Debug -derivedDataPath /private/tmp/claude-501/dd-<you> build

SLOPROOM_CATALOG_DIR=$C/cat \
SLOPROOM_DEV_SCRIPT="wait 3; snapshot $C/lib.png; select 0; mode develop; wait 4; exposure 1; wait 2; snapshot $C/dev.png; quit" \
  /private/tmp/claude-501/dd-<you>/Build/Products/Debug/sloproom.app/Contents/MacOS/sloproom &
```
(no `timeout` binary on macOS: background it and kill it after ~60s if it hasn't quit.)
Snapshots must also be written inside the container. View them with the Read tool.

- `SLOPROOM_CATALOG_DIR` overrides the catalog location (any build).
- `SLOPROOM_DEV_SCRIPT` (DEBUG builds; see `App/DevTools.swift` → `DevScript`) drives the UI and
  takes window snapshots without screen-recording permission. Commands:
  `wait <s>`, `snapshot <png>`, `mode library|develop`, `select <index>`, `source all|last|<folder name>`,
  `flag pick|none|reject`, `exposure <ev>`, `tool none|crop|mask`, `straighten <deg>`, `aspect <w>:<h>|original`, `rotate left|right`,
  `crop commit|cancel|swap`, `quit`. Add commands as needed.
  Input synthesis (`Library/Sidebar/FoldersDevScript.swift`): `key p` / `key cmd+shift+n` /
  `key shift+right` / `key delete|return|escape`, `type <text>`, `click <x> <y>` / `dclick` (window
  points, top-left origin; table views ignore the first click into an inactive window, so use
  `row <n>` to select sidebar row n), `dump` (model/sidebar state), `menus`, `whichmenu <key>`.
  Pass launch args (e.g. `-photo.autoAdvanceAfterFlag YES`) instead of writing container defaults;
  integer defaults need plist syntax: `-previews.thumbnailSize '<integer>256</integer>'`.
  More (see each file's header): `adjust <key> <v>` / `before on|off` / `window w h` / `scroll f`
  (`Develop/Adjustments/UI/DevelopDevScript.swift`), `mask linear|radial [cx cy]|brush`, `maskoverlay`,
  `maskcreate` (`Develop/Masking/UI/MaskDevScript.swift`), `lightroom preview|import <lrcat>` /
  `lightroom snapshot <png>` (`LightroomImport/LightroomImportDev.swift`), `import…`
  (`Import/ImportDevCommands.swift`), `aspect preset <name>|custom`, and in `App/IntegrationDevScript.swift`:
  `activate`, `menu <Top>/<Item>[/<Sub>]` (performs a real menu item), `folder new <n>[ in <parent>] |
  rename <n> to <m> | add <n> | move <n> | remove | delete <n>`, `selectall`, `focus <i>`, `devdump`
  (develop session state), `snapwin <png>` (newest window, e.g. Settings), `keqv <letter>`.
  Selection / filmstrip (`Library/Flags/StripDevScript.swift`): `sdump` (focused index, selection
  ranges, scroll offsets), `sfilter picked|…`, `sclick <i> [cmd|shift]`, `sflag pick|none|reject`
  (P/U/X path incl. auto advance), `sfind <file>`, `sdrag x1 y1 x2 y2` (starts a drag; synthetic
  drags never drop), `scount <folder>`.
  Zoom / panels / full screen (`Develop/Zoom/ZoomDevScript.swift`): `zoom fit|fill|<percent> [nx ny]`,
  `zoomtoggle x y`, `zmouse x y|off` (fake pointer for `key z` / ⌘=), `pan dx dy`, `magnify f [x y]`,
  `zscroll dx dy [cmd]`, `zdrag x1 y1 x2 y2 [space]` (real mouse drag, canvas points), `zspace down|up`,
  `zoomwait` (prints refine timing), `zoombench [n]`, `zoomdump`, `zactivate` (synthesized clicks only
  reach an ACTIVE app; the polite `activate` is refused while the owner uses another app),
  `zmaskdrag x1 y1 x2 y2`, `zmaskexp ev`, `panels tab|shifttab|show`,
  `fullscreen on|off|next|prev|wait|dump|snapshot <png>`, `fskey left|right|z|f|escape`, `fullz <percent> [nx ny]`,
  `winfull` (native ⌃⌘F full screen). Real trackpad gestures (CGEvents of type gesture with the HID zoom /
  zoom-toggle fields, posted through the event queue, so `ZoomEventMonitor` sees real `.magnify` /
  `.smartMagnify` NSEvents): `pinch x y factor [steps=20] [ms=16] [hold]` (began, steps, ended at canvas point
  x y; `pinch end` ends a held one), `smartmagnify x y`, `fsmagnify x y factor` (full-screen window),
  `zoomstats` (events, handler / frame ms avg + max, sharp render after the end), `sidebar` (folder sidebar
  per mode), `rawkey <keyCode> <chars> <ignoringMods> [cmd shift opt ctrl]` (explicit characters, e.g. a
  German ⌘= `rawkey 29 = = cmd shift`). `zoomdump` also prints the controller's window.
  Develop latency / preview caches (`Previews/UI/RecentRendersDevScript.swift`): `rr time next|prev|<index>`
  (ms until first image / sharp image / source loaded / final render), `rr stats`, `rr reset`, `rr dump`,
  `rr sheet` / `rr closesheet` (preview settings sheet), `rr limit <n>|reset`, `rr clean`.
  Launch args `-previews.recentRenderCount '<integer>0</integer>'` / `-previews.developPrefetch NO` switch
  the features off for before/after timings.
  Export sheet (`Export/UI/ExportDevScript.swift`): `export sheet | dest <folder> | quality <n> | run |
  wait | cancel | snapshot <png> | close | menustate | dump`, e.g.
  `activate; selectall; export sheet; export dest $C/out; export quality 70; export run; export wait; export snapshot $C/sheet.png; export close; quit`.
  Catalog transfer (`CatalogTransfer/CatalogTransferDevScript.swift`): `catalog export <file> | inspect <file> |
  replace | close | snapshot <png> | dump | roots | relink <old root path> => <new folder> | menustate`, e.g.
  `catalog export $C/out/x.sloproomcatalog; catalog close; catalog inspect $C/out/x.sloproomcatalog; catalog snapshot $C/summary.png; catalog replace; catalog snapshot $C/done.png; catalog close; catalog dump`.
  Keyboard shortcuts / tooltips (`Shortcuts/ShortcutsDevScript.swift`): `shortcut set <action id> <spec>`
  (e.g. `shortcut set pick k`, `shortcut set exportPhotos none`), `shortcut record <id> <spec>` (as typed into
  Settings > Keyboard: a conflict becomes a pending "Already used by …"), `shortcut confirm|cancel`,
  `shortcut reset <id>|resetall`, `shortcut dump` (bindings, conflicts, which actions have handlers),
  `shortcut last` (the dispatcher's last decision, e.g. `⇧⌘= → thumbnailLarger in library`),
  `shortcut search <text>`, `settings previews|drives|keyboard` (selects the tab of an open Settings window;
  open it with `menu Help/Keyboard Shortcuts…`), `menutree <Top menu>` (items + key equivalents),
  `toolbar`, `segtips`, `cellsize`, `brushdump` (brush size, cursor radius, stroke radius at the current zoom).
  `key` knows the US key codes of `= - [ ] \ ; ' , . /` and 0-9 (shortcut matching uses the key code), e.g.
  `key cmd+=`, `key cmd+shift+=`, `key cmd+[`, `key ]`.
  Virtual copies (`VirtualCopies/VirtualCopiesDevScript.swift`): `vc create` (Create Virtual Copy on the targets),
  `vc copyto <folder>`, `vc newfolder [name]`, `vc find <title>` ("L1090994.DNG" / "L1090994 · Copy 1"), `vc rename <name>`,
  `vc renamealert`, `vc remove` (no confirmation), `vc removetitle`, `vc dump` (ids, masters, titles, flags, crop, exposure),
  `vc previews <id>` (preview files on disk), `vc dropverb`, `vc sourcemask` (drag source operation masks),
  `vc droptest plain|cmd|opt <folder>` (drops the targets on a sidebar folder through SwiftUI's real drop destination with a
  fake `NSDraggingInfo` — synthetic mouse drags never drop), `vc dragmask` (logs the masks of the next real drag).
  Photo actions (`Actions/ActionsDevScript.swift`): `act dump` (targets + every action's title / availability, undo
  state), `act menu <i>` (context-menu entries for a right-click on photo i), `act run <action id> [folder]`, `act crop
  <original|preset name|W:H> [match|written]`, `act sheet bulkcrop|sync|paste`, `act sheetset aspect …|orient match|written`,
  `act sheetapply [sections]`, `act sheetclose`, `act confirm|cancel` (Reset / Remove confirmation), `act copy`, `act undo|redo`
  (the Edit menu's routing), `act wait` (bulk work finished), `act crops` (crop rect / pixel aspect / preset per photo),
  `act rclick x y <png>` (a REAL context menu: synthesized right-click, menu + window captured together, items with
  enabled state / tooltip printed, menu closed), `act toolbarmenu <png>` (Develop's Photo Actions menu), `act snapall <png>`
  (all app windows incl. sheets / dialogs), `act stripdrag <i> plain|cmd|opt <folder>` (the filmstrip cell's real drag
  provider → payload dropped through SwiftUI's drop destination, like `vc droptest`), e.g.
  `source Vineyards; mode develop; sclick 0; sclick 2 shift; act stripdrag 1 cmd <folder>; scount <folder>`.
  The sheets remember their choices in the app's UserDefaults (`actions.syncSections`, `actions.pasteSections`, `actions.bulkCrop.*`).
  Shortcut rebinding / brush size / thumbnail size write the app's (shared!) UserDefaults: `shortcut resetall` and
  restore `library.cellSize` when you are done.
  Synthesized keys are delivered to the main window, but menu key equivalents only match while the app
  is active: run `activate` first, and don't use the Mac meanwhile (focus stealing makes key tests flaky).
  A menu item that opens a modal alert blocks the script (the alert's run loop doesn't run DevScript).
- Photos outside the container need a root bookmark (File > "Add Folder in Place (Dev)…" creates one via the open panel).

## sdimport_check.swift

SD card import engine (scan, RAW+JPEG sidecars, duplicates, safe copy into date folders, catalog
insert + folder, cancel, no-write-access error). Copies sample pairs into a fake card first:

```sh
Tools/harness.sh /private/tmp/claude-501/out-sdimport/sdimport_check Tools/sdimport_check.swift \
  sloproom/Import/ImportEngine.swift sloproom/Import/Catalog+Import.swift
/private/tmp/claude-501/out-sdimport/sdimport_check [sample-dir] [out-dir]
```

The import sheet can be driven in the sandboxed app with `import…` DevScript commands
(`Import/ImportDevCommands.swift`), e.g.
`importsheet; wait 2; importsource $C/card; importdest $C/dest; importfolder Test; wait 3; importsnapshot $C/sheet.png; importrun; wait 3; snapshot $C/lib.png; quit`
(`importclose` before `quit` if a sheet is still open).

## All harnesses

Build from the repo root (engine default set + the extra files listed), run, expect `ALL … PASS…`:

| Harness | Extra files | Run args |
|---|---|---|
| `foundation_check` | – | `[photo-dir] [out-dir]` |
| `lrimport_check` | `sloproom/LightroomImport/{LightroomCatalogReader,LightroomImportPlan,Catalog+LightroomImport,RootAccess}.swift sloproom/App/FolderTree.swift` | `<catalog.lrcat> [out-dir]` (a COPY of the owner's catalog) |
| `sdimport_check` | `sloproom/Import/ImportEngine.swift sloproom/Import/Catalog+Import.swift` | `[sample-dir] [out-dir]` |
| `folders_check` | `sloproom/App/FolderTree.swift sloproom/Library/Sidebar/{Catalog+FolderManagement,FolderDragPayload}.swift` | `[out-dir]` |
| `previews_check` | – | `[photo-dir] [out-dir]` |
| `develop_check` | – | `[dng] [out-dir] [only-name-substring]` |
| `masks_check` | `sloproom/Develop/DevelopSession.swift sloproom/Develop/Masking/UI/{MaskInteraction,MaskToolState,DevelopSession+Masks}.swift sloproom/Develop/Crop/{DevelopSession+Crop,CropMath,Catalog+CropPresets}.swift` | `[dng] [out-dir]` |
| `crop_check` | `sloproom/Develop/Crop/CropMath.swift sloproom/Develop/Crop/Catalog+CropPresets.swift` | `[photo-dir] [out-dir]` |
| `zoom_check` | `sloproom/Develop/Zoom/RegionRenderer.swift` | `[dng]` (viewport math incl. free pinch levels, steps from them, pinch anchor held over 20 steps; region render == full render, 1:1 timings) |
| `catalog_transfer_check` | `sloproom/CatalogTransfer/CatalogTransfer.swift sloproom/LightroomImport/RootAccess.swift` | `[catalog-dir to COPY] [out-dir]` (default: the realistic catalog copy `…/Data/tmp/catalog/pristine`, `/private/tmp/claude-501/catalog-out/run`) |
| `recentrenders_check` | – | `[dng] [out-dir]` (RecentRenders store/lookup/eviction/stale/purge, Clean Cache, JPEG vs HEIC timings) |
| `lrmatch_check` | – | `[dng] [tuning-dir] [label] [sliders] [nocrop]` or `fit <spec> [evals]` (sliders vs Lightroom exports, see above) |
| `export_check` | `sloproom/Export/ExportEngine.swift sloproom/Develop/Crop/CropMath.swift` | `[photo-dir] [out-dir]` (default `/private/tmp/claude-501/out-export`; `look/` = downscaled exports + Develop renders) |
| `shortcuts_check` | `HARNESS_NO_DEFAULT=1`, `sloproom/Shortcuts/ShortcutModel.swift sloproom/Shortcuts/ShortcutStore.swift` | – (defaults, overrides persist, conflicts per scope, resolution, reset, formatting; own UserDefaults suite) |
| `vcopies_check` | `sloproom/VirtualCopies/{Catalog+VirtualCopies,VirtualCopyPreviews}.swift sloproom/Import/Catalog+Import.swift sloproom/LightroomImport/{RootAccess,LightroomCatalogReader,LightroomImportPlan,Catalog+LightroomImport}.swift sloproom/Export/ExportEngine.swift sloproom/Develop/Crop/CropMath.swift` | `[realistic catalog dir to COPY] [sample.jpg] [out-dir]` (defaults: `…/Data/tmp/vcopies/pristine`, `…/Data/tmp/folders/photos/L1090230.JPG`; schema v2 migration of a fresh v1 + the realistic copy, copies, sorting, import dedupe, relink, removal, preview seeding, export names) |
| `actions_check` | `sloproom/Actions/{PhotoActionSpec,EditSections,BulkCrop,Catalog+BulkEdits}.swift sloproom/Shortcuts/ShortcutModel.swift sloproom/Develop/Crop/{CropMath,Catalog+CropPresets}.swift` | `[out-dir]` (registry arity / modes / enablement / shortcut titles + no default-key conflicts, target resolution, Bulk Crop math for every preset × orientation × portrait / landscape / square / rotated / straightened / flipped / EXIF-rotated photo, Paste / Sync section masking, bulk apply + one-step undo / redo on a temp catalog, 2,000-photo timing) |

## lrmatch_check.swift (Develop sliders vs Lightroom)

Calibrates the sliders against real Lightroom Classic exports of one RAW (one slider changed per
folder). References are downscaled copies made ONCE with `sips` from the owner's exports in
`~/Pictures/Lightroom Tuning/<Slider>/L1100118_<value>.jpg` (read-only; never re-read the 40 MB originals):

```sh
T=~/Library/Containers/dev.snivik.sloproom/Data/tmp/tuning
sips -Z 1600 -s formatOptions 90 <export> --out $T/ref/<Slider>/<value>.jpg          # whole image
sips -c 1067 1600 -s formatOptions 92 <export> --out $T/ref100/<Slider>/<value>.jpg  # 1:1 center crop
sips -c 1067 1600 --cropOffset 1177 2615 -s formatOptions 92 <export> --out $T/refhl/Highlights/<value>.jpg  # 1:1 bright metal
Tools/harness.sh /private/tmp/claude-501/tuning-out/lrmatch_check Tools/lrmatch_check.swift
/private/tmp/claude-501/tuning-out/lrmatch_check [dng] [tuning-dir] [label] [slider,slider…] [nocrop]
/private/tmp/claude-501/tuning-out/lrmatch_check fit <spec> [max-evals]      # Nelder–Mead over model constants
TONE="hn.slope=0.4,cl.pos=1.2" /private/tmp/claude-501/tuning-out/lrmatch_check …   # try constants without rebuilding
```

- Every `ref/<Slider>` folder present is calibrated (folder name → EditSettings field: Exposure, Contrast,
  Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Vibrance, Saturation).
- Renders the DNG through the real `RenderPipeline` (1600 px whole image; full-resolution render cropped
  to the same 1:1 windows, aligned automatically), writes `out/<label>/ours…/<Slider>/<value>.jpg`,
  side-by-side montages `out/<label>/montage…/<Slider>.jpg` (LR left, ours right) and a ±50 ladder
  `out/<label>/ladder/<Slider>.jpg`. LOOK at the montages.
- Metrics compare the slider's EFFECT (ours(v) − ours(0) vs LR(v) − LR(0), CIELAB): per LR-0 L* zone
  mean ΔL*/ΔC*, `zoneL`/`zoneC` (RMS over zones), `eff%` (per-pixel effect error / LR effect, 4×4 boxes),
  band-pass energy ratios (fine/medium/coarse) and dark-channel shift; plus the 0-vs-0 baseline per zone.
  `CURVES=1` prints transfer tables (L*(0) bin → mean L*(v), chroma ratio). Summary in `out/<label>/metrics.tsv`.
- Fit specs (`fitSpecs` in the file) name the `AdjustmentOps.ToneModel` / `PresenceModel` constants they
  optimize; paste the printed values into those structs.

## ax_help_audit.swift (tooltips / accessibility labels)

Out-of-process Accessibility client (SwiftUI only exposes its full accessibility tree to one; the terminal
needs Accessibility permission, the app stays sandboxed). Lists every button / checkbox / segment / pop-up /
slider / menu button without a tooltip, and icon-only controls without a label (or an SF Symbol name as label):

```sh
xcrun swiftc -O Tools/ax_help_audit.swift -o /private/tmp/claude-501/<you>/ax_help_audit
/private/tmp/claude-501/<you>/ax_help_audit <app pid> [window title substring] [-v]
/private/tmp/claude-501/<you>/ax_help_audit <app pid> -press "Edit Presets…"   # AXPress a control (opens sheets without DevScript)
```
Skips AppKit chrome it can't annotate (window buttons, scroll bars, List outline disclosure triangles).

e.g. `Tools/harness.sh /private/tmp/claude-501/<you>/crop_check Tools/crop_check.swift sloproom/Develop/Crop/CropMath.swift sloproom/Develop/Crop/Catalog+CropPresets.swift`
(the harnesses compile in parallel fine; ~1–3 min each with `-O`).
