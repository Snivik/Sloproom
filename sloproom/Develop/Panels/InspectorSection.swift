//
//  InspectorSection.swift
//  sloproom
//
//  Collapsible inspector section (expanded state persisted per section id).
//

import SwiftUI

struct InspectorSection<Content: View>: View {
    let title: String
    let onReset: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @AppStorage private var isExpanded: Bool

    init(_ title: String, id: String? = nil, onReset: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.onReset = onReset
        self.content = content
        _isExpanded = AppStorage(wrappedValue: true, "develop.section.\(id ?? title).expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .font(.caption.weight(.semibold))
                            .frame(width: 10)
                        Text(title).font(.headline)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let onReset, isExpanded {
                    Button("Reset", action: onReset)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if isExpanded {
                content()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider()
    }
}

/// Placeholder body for panels that are not implemented yet.
struct PanelTODO: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
