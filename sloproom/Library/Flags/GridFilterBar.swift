//
//  GridFilterBar.swift
//  sloproom
//
//  Bar above the Library grid: flag filter, "Include Subfolders" (when a folder is shown),
//  photo / selection count.
//

import SwiftUI

struct GridFilterBar: View {
    @Environment(AppModel.self) private var model

    private static let filters: [FlagFilter] = [.all, .picked, .unflagged, .rejected, .notRejected]

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            // Not fixed-size: segments shrink in narrow windows instead of widening the window.
            Picker("Flag Filter", selection: $model.filter.flag) {
                ForEach(Self.filters, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .help("Show photos by flag")
            .segmentHelp(Self.filters.map(\.help))

            if model.shownFolderID != nil {
                Toggle("Subfolders", isOn: $model.includeSubfolders)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Also show photos of this folder's subfolders")
                    .accessibilityLabel("Include Subfolders")
            }

            Spacer(minLength: 8)

            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countText: String {
        let n = model.photos.count
        let s = model.selection.count
        let photos = "\(n.formatted()) photo\(n == 1 ? "" : "s")"
        return s > 0 ? "\(photos), \(s.formatted()) selected" : photos
    }
}

extension FlagFilter {
    /// Tooltip of the filter segment.
    var help: String {
        switch self {
        case .all: "Show all photos"
        case .picked: "Show picked photos only"
        case .rejected: "Show rejected photos only"
        case .unflagged: "Show photos without a flag"
        case .notRejected: "Show picked and unflagged photos (hide rejects)"
        }
    }
}
