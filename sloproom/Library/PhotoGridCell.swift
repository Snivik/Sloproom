//
//  PhotoGridCell.swift
//  sloproom
//

import SwiftUI

struct PhotoGridCell: View {
    let photo: Photo
    let isSelected: Bool
    let isFocused: Bool
    /// Click on the (hover) flag badge: toggle pick for this photo.
    var onTogglePick: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(photo: photo, level: .thumbnail)
                .rejectedVeil(photo.flag == .reject)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if photo.hasEdits {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .padding(3)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
            HStack(spacing: 4) {
                Text(photo.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if photo.rating > 0 {
                    Text(String(repeating: "★", count: photo.rating))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(alignment: .topLeading) {
            FlagBadge(flag: photo.flag, isHovering: isHovering, onTogglePick: onTogglePick).padding(11)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
