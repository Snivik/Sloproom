//
//  ZoomDevScript.swift
//  sloproom
//
//  DevScript commands (DEBUG) for zoom / panels / full screen (see App/DevTools.swift):
//    zoom fit|fill|<percent> [nx ny]   set the Develop zoom (centered on displayed-normalized nx ny)
//    zoomtoggle <x> <y>                Z / click behaviour at canvas point x y
//    zmouse <x> <y>|off                pretend the pointer is at canvas point x y (for `key z`, ⌘=)
//    pan <dx> <dy>                     pan by view points
//    magnify <factor> [x y]            pinch by factor around canvas point
//    zscroll <dx> <dy> [cmd]           real scroll-wheel event at the canvas center (⌘ = zoom)
//    zdrag <x1> <y1> <x2> <y2> [space] real mouse drag in canvas points (optionally holding space)
//    zspace down|up                    real space key down / up
//    zoomwait                          wait (≤ 15 s) until the sharp tile is up; prints timing
//    zoombench [n]                     time n region renders of the current view (1:1 etc.)
//    zoomdump                          zoom / tile / panel / canvas state
//    panels tab|shifttab|show          Tab / ⇧Tab actions (or reset to all visible)
//    fullscreen on|off|next|prev|dump|snapshot <png>|wait   full-screen preview
//    zactivate                         force-activate the app (synthesized clicks need an active window)
//    zmaskdrag <x1> <y1> <x2> <y2>     drive MaskInteraction like MaskOverlayView (no real events)
//    zmaskexp <ev>                     exposure of the selected mask
//    fskey left|right|z|f|escape       real key event to the full-screen window
//    winfull                           toggle the main window's native full screen (⌃⌘F)
//    fullz <percent> [nx ny]           zoom in the full-screen preview
//

#if DEBUG
import AppKit
import CoreGraphics
import Foundation

enum ZoomDevScript {
    static let commands: Set<String> = ["zoom", "zoomtoggle", "zmouse", "pan", "magnify", "zscroll", "zdrag", "zspace",
                                        "zoomwait", "zoombench", "zoomdump", "panels", "fullscreen", "winfull", "fullz", "zactivate", "zmaskdrag", "zmaskexp", "fskey"]

    static func run(_ command: String, _ arg: String, model: AppModel) async {
        let zoom = ZoomController.develop
        let v = arg.split(separator: " ").map(String.init)
        let nums = v.compactMap { Double($0) }
        switch command {
        case "zoom", "fullz":
            let z = command == "zoom" ? zoom : FullScreenPreview.shared.zoom
            guard let first = v.first else { return }
            let level: ZoomLevel = first == "fit" ? .fit : first == "fill" ? .fill : .ratio((Double(first) ?? 100) / 100)
            if v.count >= 3, let x = Double(v[1]), let y = Double(v[2]) { z.setLevel(level, centeredOn: CGPoint(x: x, y: y)) }
            else { z.setLevel(level, anchor: nil) }
        case "zoomtoggle":
            if nums.count == 2 { zoom.toggle(at: CGPoint(x: nums[0], y: nums[1])) }
        case "zmouse":
            zoom.debugMouseLocation = nums.count == 2 ? CGPoint(x: nums[0], y: nums[1]) : nil
            FullScreenPreview.shared.zoom.debugMouseLocation = zoom.debugMouseLocation
        case "pan":
            if nums.count == 2 { zoom.pan(by: CGSize(width: nums[0], height: nums[1])) }
        case "magnify":
            let anchor = nums.count >= 3 ? CGPoint(x: nums[1], y: nums[2]) : nil
            zoom.magnify(by: nums.first ?? 1, anchor: anchor)
        case "zscroll":
            scroll(dx: nums.count > 0 ? nums[0] : 0, dy: nums.count > 1 ? nums[1] : 0, command: v.contains("cmd"), zoom: zoom)
        case "zdrag":
            guard nums.count >= 4 else { return }
            await drag(from: CGPoint(x: nums[0], y: nums[1]), to: CGPoint(x: nums[2], y: nums[3]), space: v.contains("space"), zoom: zoom)
        case "zspace":
            spaceKey(down: arg != "up", zoom: zoom)
        case "zoomwait":
            let start = Date()
            let count = zoom.refineCount
            try? await Task.sleep(for: .milliseconds(150))
            while Date().timeIntervalSince(start) < 15, zoom.inFlight || (zoom.isZoomed && zoom.visibleTile == nil && zoom.refineCount == count) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            print(String(format: "DevScript zoomwait: %.0f ms (last region render %.0f ms, cachedDecode=%@, tile=%@)",
                         Date().timeIntervalSince(start) * 1000, zoom.lastRefineMS, zoom.lastRefineCached ? "yes" : "no",
                         zoom.visibleTile != nil ? "yes" : "no"))
        case "zoombench":
            await bench(n: Int(arg) ?? 5, zoom: zoom, session: model.developSession)
        case "zoomdump":
            dump(zoom, name: "develop")
            if let m = model.developSession?.selectedMask {
                if let r = m.radial { print(String(format: "DevScript zoomdump: selected radial center=(%.4f, %.4f) rx=%.4f ry=%.4f", r.center.x, r.center.y, r.radiusX, r.radiusY)) }
                if let b = m.brush { print("DevScript zoomdump: selected brush strokes=\(b.strokes.count) first=\(b.strokes.first?.points.first.map { "(\($0.x), \($0.y))" } ?? "-") radius=\(b.strokes.first?.radius ?? 0)") }
            }
            let p = DevelopPanels.shared
            print("DevScript zoomdump: panels sidebar=\(p.sidebarHidden ? "hidden" : "shown") inspector=\(p.inspectorHidden ? "hidden" : "shown") filmstrip=\(p.filmstripHidden ? "hidden" : "shown")")
        case "panels":
            switch arg {
            case "tab": DevelopPanels.shared.toggleSidePanels()
            case "shifttab": DevelopPanels.shared.toggleLightsOut()
            default:
                DevelopPanels.shared.sidebarHidden = false
                DevelopPanels.shared.inspectorHidden = false
                DevelopPanels.shared.filmstripHidden = false
            }
        case "fullscreen":
            let fs = FullScreenPreview.shared
            switch v.first ?? "" {
            case "on": fs.show(model: model)
            case "off": fs.close()
            case "next": fs.move(by: 1)
            case "prev": fs.move(by: -1)
            case "wait":
                let start = Date()
                try? await Task.sleep(for: .milliseconds(100))
                while Date().timeIntervalSince(start) < 20, fs.isShowing, fs.isPlaceholder || fs.image == nil {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                print(String(format: "DevScript fullscreen wait: %.0f ms (screen render %.0f ms)", Date().timeIntervalSince(start) * 1000, fs.lastRenderMS))
            case "snapshot":
                if let w = fs.window, v.count > 1 { snapshot(window: w, to: v[1]) }
            default:
                print("DevScript fullscreen: showing=\(fs.isShowing) photo=\(fs.photoID.map(String.init) ?? "-") image=\(fs.image.map { "\($0.width)x\($0.height)" } ?? "-") placeholder=\(fs.isPlaceholder) key=\(fs.window?.isKeyWindow ?? false) frame=\(fs.window?.frame ?? .zero) focused=\(model.focusedPhotoID.map(String.init) ?? "-")")
                dump(fs.zoom, name: "fullscreen")
            }
        case "zactivate":
            // Forceful activation (the polite NSApp.activate() is refused while another app is in use).
            _ = NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
            mainWindow(zoom)?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            print("DevScript zactivate: active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
        case "zmaskdrag":
            // Drives MaskInteraction exactly like MaskOverlayView does (same MaskSpace from the zoomed
            // imageRect), for when synthesized mouse events can't reach the inactive app.
            guard nums.count >= 4, let session = model.developSession else { return }
            let space = MaskSpace(geometry: session.canvasGeometry(imageRect: zoom.imageRect))
            var interaction = MaskInteraction()
            let a = CGPoint(x: nums[0], y: nums[1]), b = CGPoint(x: nums[2], y: nums[3])
            for i in 0...10 {
                let t = CGFloat(i) / 10
                interaction.dragChanged(start: a, location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                        space: space, session: session, tool: MaskToolState.shared, erase: false)
            }
            interaction.dragEnded(location: b, space: space, session: session)
            print("DevScript zmaskdrag: masks=\(session.settings.masks.count) view \(a) -> mask \(space.geometry.maskPoint(fromView: a))")
        case "zmaskexp":   // exposure of the selected mask
            if let s = model.developSession, let id = s.selectedMaskID { s.updateMask(id) { $0.adjustments.exposure = nums.first ?? 1 } }
        case "fskey":   // real key event to the full-screen window: left|right|z|f|escape
            guard let w = FullScreenPreview.shared.window else { print("DevScript fskey: not showing"); return }
            let map: [String: (UInt16, String)] = ["left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                                                   "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
                                                   "z": (6, "z"), "f": (3, "f"), "escape": (53, "\u{1b}")]
            guard let (code, chars) = map[arg] else { return }
            let flags: NSEvent.ModifierFlags = code >= 123 ? [.function, .numericPad] : []
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
            }
        case "winfull":
            NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0 !== FullScreenPreview.shared.window }?.toggleFullScreen(nil)
        default: break
        }
    }

    private static func dump(_ zoom: ZoomController, name: String) {
        let vp = zoom.viewport
        let t = zoom.visibleTile
        print("DevScript zoomdump[\(name)]: level=\(CanvasViewport.label(vp.level)) ratio=\(String(format: "%.3f", vp.pixelRatio)) "
              + "center=(\(String(format: "%.3f, %.3f", vp.center.x, vp.center.y))) imageRect=\(vp.imageRect.integral) canvas=\(vp.canvasSize) "
              + "displayed=\(vp.displayedSize) scale=\(vp.displayScale) canvasFrame=\(zoom.canvasFrame) locked=\(zoom.isLocked) space=\(zoom.spaceHeld) "
              + "tile=\(t.map { "\($0.image.width)x\($0.image.height)@\($0.normalizedRect)" } ?? "none") "
              + "lastRefine=\(String(format: "%.0f", zoom.lastRefineMS))ms refines=\(zoom.refineCount) mouse=\(zoom.mouseLocation.map { "\($0)" } ?? "-")")
    }

    private static func mainWindow(_ zoom: ZoomController) -> NSWindow? {
        zoom.window ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    /// Canvas point → window base coordinates (bottom-left origin).
    private static func windowPoint(_ p: CGPoint, zoom: ZoomController, window: NSWindow) -> NSPoint {
        let content = window.contentView!
        let yTop = zoom.canvasFrame.minY + p.y
        let local = NSPoint(x: zoom.canvasFrame.minX + p.x, y: content.isFlipped ? yTop : content.bounds.height - yTop)
        return content.convert(local, to: nil)
    }

    private static func scroll(dx: Double, dy: Double, command: Bool, zoom: ZoomController) {
        guard let window = mainWindow(zoom),
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { return }
        let c = windowPoint(CGPoint(x: zoom.canvasFrame.width / 2, y: zoom.canvasFrame.height / 2), zoom: zoom, window: window)
        let screen = window.convertPoint(toScreen: c)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
        if command { cg.flags = .maskCommand }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let e = NSEvent(cgEvent: cg) else { return }
        print("DevScript zscroll: event window=\(e.window === window) loc=\(e.locationInWindow) dy=\(e.scrollingDeltaY) precise=\(e.hasPreciseScrollingDeltas)")
        NSApp.postEvent(e, atStart: false)
    }

    private static func spaceKey(down: Bool, zoom: ZoomController) {
        guard let window = mainWindow(zoom),
              let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
        else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func drag(from a: CGPoint, to b: CGPoint, space: Bool, zoom: ZoomController) async {
        guard let window = mainWindow(zoom) else { return }
        if space { spaceKey(down: true, zoom: zoom); try? await Task.sleep(for: .milliseconds(100)) }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: windowPoint(p, zoom: zoom, window: window), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, a) { NSApp.sendEvent(e) }
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            try? await Task.sleep(for: .milliseconds(16))
            if let e = event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { NSApp.sendEvent(e) }
        }
        try? await Task.sleep(for: .milliseconds(16))
        if let e = event(.leftMouseUp, b) { NSApp.sendEvent(e) }
        if space { try? await Task.sleep(for: .milliseconds(50)); spaceKey(down: false, zoom: zoom) }
    }

    private static func bench(n: Int, zoom: ZoomController, session: DevelopSession?) async {
        guard let session, let source = session.source else { print("DevScript zoombench: no source"); return }
        let vp = zoom.viewport
        let scale = min(1, vp.pixelRatio)
        let region = vp.visibleDisplayedRect
        let settings = session.zoomDisplaySettings, applyCrop = session.renderedWithCrop
        let renderer = RegionRenderer()
        let times: [String] = await Task.detached {
            var out: [String] = []
            for i in 0..<max(1, n) {
                let r = region.offsetBy(dx: CGFloat(i % 3) * region.width * 0.1, dy: 0)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if let res = renderer.render(source: source, settings: settings, applyCrop: applyCrop, scale: scale, region: r) {
                    out.append(String(format: "%.0fms(%dx%d%@)", res.milliseconds, res.image.width, res.image.height, res.usedCachedDecode ? ",cached" : ""))
                }
            }
            return out
        }.value
        print("DevScript zoombench: scale=\(String(format: "%.3f", scale)) region=\(region) renders=\(times.joined(separator: " "))")
    }

    static func snapshot(window: NSWindow, to path: String) {
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let image = unsafeBitCast(sym, to: CaptureFn.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("DevScript: snapshot failed"); return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("DevScript: wrote \(path) (\(image.width)x\(image.height))")
    }
}
#endif
