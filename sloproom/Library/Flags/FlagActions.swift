//
//  FlagActions.swift
//  sloproom
//
//  Pick / Unflag / Reject.
//
//  Keyboard approach: P / U / X are real menu key equivalents without modifiers (Photo menu,
//  `SloproomCommands.letterButton`). Menu key equivalents work in every mode (Library grid,
//  Develop, sidebar focused) because AppKit matches them before keyDown reaches any view, and
//  `TextInputGuard` re-types the letter when a text field (inline folder rename, search) is
//  being edited, so typing never flags photos. They act on `AppModel.actionTargetIDs`
//  (Library: every selected photo; Develop: the current photo).
//

import SwiftUI

enum FlagActions {
    static let autoAdvanceKey = "photo.autoAdvanceAfterFlag"

    static var autoAdvance: Bool { UserDefaults.standard.bool(forKey: autoAdvanceKey) }

    /// Flags the action targets; with Auto Advance on and a single target, moves to the next photo.
    static func setFlag(_ flag: Flag, model: AppModel) {
        let targets = model.actionTargetIDs
        guard !targets.isEmpty else { return }
        model.setFlag(flag)
        if autoAdvance, targets.count == 1 { model.moveFocus(by: 1) }
    }

    /// The hover badge on a grid cell: pick ↔ unflag for that one photo.
    static func togglePick(_ photo: Photo, model: AppModel) {
        do { try model.catalog.setFlag(photo.flag == .pick ? .none : .pick, for: [photo.id]) } catch { model.report(error) }
    }
}

/// Photo menu toggle (default off).
struct AutoAdvanceToggle: View {
    @AppStorage(FlagActions.autoAdvanceKey) private var autoAdvance = false

    var body: some View {
        Toggle("Auto Advance After Flagging", isOn: $autoAdvance)
    }
}

/// Flag badge for grid / filmstrip cells, monochrome like Lightroom: white flag = picked,
/// white flag with × = rejected, outline flag on hover (click toggles pick). A dark translucent
/// backing + shadow keeps the white glyph readable on bright photos.
struct FlagBadge: View {
    let flag: Flag
    let isHovering: Bool
    /// Click action (grid). nil = display only (filmstrip): no hit testing, clicks reach the cell.
    var onTogglePick: (() -> Void)?
    /// Backing diameter; the filmstrip uses a smaller badge than the grid.
    var size: CGFloat = 22

    var body: some View {
        if let onTogglePick {
            if flag != .none || isHovering {
                Button { onTogglePick() } label: { icon }
                    .buttonStyle(.plain)
                    .help(flag == .pick ? "Picked — click to unflag" : flag == .reject ? "Rejected" : "Click to pick (P)")
            }
        } else if flag != .none {
            icon.allowsHitTesting(false)
        }
    }

    private var icon: some View {
        ZStack {
            switch flag {
            case .pick:
                glyph("flag.fill")
            case .reject:
                glyph("flag.fill")
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "xmark")
                            .font(.system(size: size * 0.3, weight: .black))
                            .foregroundStyle(.white)
                            .padding(size * 0.06)
                            .background(Color(white: 0.12), in: Circle())
                            .offset(x: size * 0.1, y: size * 0.1)
                    }
            case .none:
                glyph("flag").opacity(0.9)
            }
        }
        .frame(width: size, height: size)
        .background(.black.opacity(flag == .none ? 0.3 : 0.42), in: Circle())
        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
        .contentShape(Circle())
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
    }
}

extension View {
    /// Lightroom-style reject veil: the image is desaturated and washed out towards mid grey
    /// (a 55 % grey overlay: `contrast(0.45)` maps v → 0.45·v + 0.55·0.5). Color effects only
    /// touch drawn pixels, so the letterbox around an aspect-fit thumbnail stays untouched.
    func rejectedVeil(_ isRejected: Bool) -> some View {
        saturation(isRejected ? 0.25 : 1)
            .contrast(isRejected ? 0.45 : 1)
    }
}
