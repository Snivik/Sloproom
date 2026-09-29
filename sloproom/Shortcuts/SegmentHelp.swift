//
//  SegmentHelp.swift
//  sloproom
//
//  Per-segment tooltips for segmented Pickers. SwiftUI's `.help` on a segmented Picker (or on
//  its segment labels) never reaches the individual NSSegmentedControl segments, so hovering a
//  segment shows nothing and VoiceOver has no hint. `.segmentHelp([...])` puts an invisible
//  probe behind the picker that finds the NSSegmentedControl it covers and calls
//  `setToolTip(_:forSegment:)` (in segment order; also sets the control's own tooltip).
//
//    Picker(...) { ... }.pickerStyle(.segmented).segmentHelp(["Fit", "Fill", "1:1"])
//

import AppKit
import SwiftUI

extension View {
    /// Tooltips of a segmented picker's segments, in order. `control` = the whole control's tooltip.
    func segmentHelp(_ tips: [String], control: String? = nil) -> some View {
        background(SegmentHelpProbe(tips: tips, control: control).allowsHitTesting(false))
    }
}

private struct SegmentHelpProbe: NSViewRepresentable {
    let tips: [String]
    let control: String?

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.tips = tips
        view.control = control
        view.scheduleApply()
    }

    final class ProbeView: NSView {
        var tips: [String] = []
        var control: String?
        private var pending = false
        /// The control found last time (SwiftUI may rebuild it or reset its tooltips on updates).
        private weak var found: NSSegmentedControl?
        private var timer: Timer?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            guard window != nil else { return }
            // AppKit / SwiftUI clear segment tooltips on some updates (e.g. when the window title
            // changes); nothing observable signals it, so re-check twice a second (a few string
            // compares when nothing changed).
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            scheduleApply()
        }

        private func refresh() {
            guard let seg = found, seg.window === window else { scheduleApply(); return }
            if (0..<min(seg.segmentCount, tips.count)).contains(where: { seg.toolTip(forSegment: $0) != tips[$0] }) {
                set(seg)
            }
        }

        override func layout() {
            super.layout()
            scheduleApply()
        }

        func scheduleApply() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.apply()
            }
        }

        private func apply() {
            guard window != nil, let root = hostRoot() else { return }
            let mine = convert(bounds, to: nil)
            guard mine.width > 0, let seg = Self.segmentedControl(in: root, covering: mine) else { return }
            found = seg
            set(seg)
        }

        private func set(_ seg: NSSegmentedControl) {
            for i in 0..<min(seg.segmentCount, tips.count) where seg.toolTip(forSegment: i) != tips[i] {
                seg.setToolTip(tips[i], forSegment: i)
            }
            if let control, seg.toolTip != control { seg.toolTip = control }
        }

        /// The nearest ancestor that contains other views (SwiftUI hosts siblings there).
        private func hostRoot() -> NSView? {
            var v: NSView? = superview
            for _ in 0..<6 {
                guard let current = v else { break }
                if Self.containsSegmented(current) { return current }
                v = current.superview
            }
            return window?.contentView
        }

        private static func containsSegmented(_ view: NSView) -> Bool {
            if view is NSSegmentedControl { return true }
            return view.subviews.contains { containsSegmented($0) }
        }

        private static func segmentedControl(in view: NSView, covering rect: CGRect) -> NSSegmentedControl? {
            if let seg = view as? NSSegmentedControl {
                let f = seg.convert(seg.bounds, to: nil)
                if f.intersects(rect), abs(f.midX - rect.midX) < max(8, rect.width / 3), abs(f.midY - rect.midY) < max(8, rect.height) { return seg }
            }
            for sub in view.subviews {
                if let found = segmentedControl(in: sub, covering: rect) { return found }
            }
            return nil
        }
    }
}

// MARK: - Toolbar items

extension View {
    /// Tooltips for the window's NSToolbar items, keyed by item label or identifier (SwiftUI's
    /// `.help` on a toolbar button doesn't reach the NSToolbarItem, and AppKit's own items —
    /// the sidebar toggle — have none).
    func toolbarHelp(_ tips: [String: String]) -> some View {
        background(ToolbarHelpProbe(tips: tips).allowsHitTesting(false))
    }
}

private struct ToolbarHelpProbe: NSViewRepresentable {
    let tips: [String: String]

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.tips = tips
        view.apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in view?.apply() }   // items appear lazily
    }

    final class ProbeView: NSView {
        var tips: [String: String] = [:]

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let toolbar = window?.toolbar else { return }
            for item in toolbar.items {
                guard let tip = tips[item.itemIdentifier.rawValue] ?? tips[item.label] else { continue }
                if item.toolTip != tip { item.toolTip = tip }
            }
        }
    }
}
