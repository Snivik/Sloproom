//
//  WhiteBalancePickerOverlay.swift
//  sloproom
//
//  Canvas layer while the white-balance eyedropper is armed: crosshair cursor, click a neutral
//  point to set custom WB from it (Esc or a click outside the image cancels).
//

import AppKit
import SwiftUI

struct WhiteBalancePickerOverlay: View {
    let session: DevelopSession
    let imageRect: CGRect

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .onTapGesture { location in
                session.isPickingWhiteBalance = false
                guard imageRect.contains(location) else { return }
                let p = session.canvasGeometry(imageRect: imageRect).maskPoint(fromView: location)
                guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                session.setWhiteBalance(from: .point(p))
            }
            .onExitCommand { session.isPickingWhiteBalance = false }
            .onDisappear { NSCursor.arrow.set() }
    }
}

/// "Before" badge shown on the canvas while Before/After is on.
struct BeforeBadge: View {
    var body: some View {
        Text("Before")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(24)
            .allowsHitTesting(false)
    }
}
