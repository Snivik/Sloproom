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

/// Flag badge for grid cells: white flag = picked, black flag with × = rejected, outline flag on
/// hover (click toggles pick).
struct FlagBadge: View {
    let flag: Flag
    let isHovering: Bool
    var onTogglePick: (() -> Void)?
    /// Circle diameter; the filmstrip uses a smaller badge than the grid.
    var size: CGFloat = 22

    var body: some View {
        if flag != .none || (isHovering && onTogglePick != nil) {
            Button { onTogglePick?() } label: { icon }
                .buttonStyle(.plain)
                .disabled(onTogglePick == nil)
                .help(flag == .pick ? "Picked — click to unflag" : flag == .reject ? "Rejected" : "Click to pick (P)")
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch flag {
        case .pick:   glyph("flag.fill", color: .white, background: Color(red: 0.16, green: 0.62, blue: 0.33))
        case .reject: glyph("xmark", color: .white, background: Color(red: 0.82, green: 0.2, blue: 0.2))
        case .none:   glyph("flag", color: .white.opacity(0.9), background: .black.opacity(0.35))
        }
    }

    private func glyph(_ name: String, color: Color, background: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(background, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(flag == .none ? 0 : 0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .contentShape(Circle())
    }
}
