//
//  SettingsSectionsSheet.swift
//  sloproom
//
//  Section checklist for Sync Settings… (from the focused photo to the other targets) and
//  Choose Settings to Paste… (the copied settings onto the targets). Sections match the Develop
//  panels (`EditSection`); the choice is remembered per kind (Sync: everything but Crop & Rotate
//  by default; Paste: the global adjustments, which Paste Settings ⇧⌘V then keeps using).
//

import SwiftUI

struct SettingsSectionsSheet: View {
    enum Kind: Equatable {
        case sync(source: Int64)
        case paste
    }

    let model: AppModel
    let kind: Kind
    let targets: [Int64]
    @State private var sections: Set<EditSection> = []
    @Environment(\.dismiss) private var dismiss

    static let syncSectionsKey = "actions.syncSections"

    static var syncSections: Set<EditSection> {
        get { EditSection.decode(UserDefaults.standard.string(forKey: syncSectionsKey)) ?? EditSection.syncDefault }
        set { UserDefaults.standard.set(EditSection.encode(newValue), forKey: syncSectionsKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(EditSection.allCases) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { sections.contains(section) },
                        set: { if $0 { sections.insert(section) } else { sections.remove(section) } }
                    ))
                    .help(section.help)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.leading, 4)
            HStack {
                Button("Check All") { sections = Set(EditSection.allCases) }
                    .help("Select every section")
                Button("Check None") { sections = [] }
                    .help("Clear every section")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without changing any photo")
                Button(applyTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sections.isEmpty || targets.isEmpty)
                    .help(applyHelp)
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { sections = kind == .paste ? DevelopClipboard.pasteSections : Self.syncSections }
    }

    private var title: String {
        switch kind {
        case .sync: "Sync Settings"
        case .paste: "Choose Settings to Paste"
        }
    }

    private var subtitle: String {
        let n = PhotoActionSpec.photos(targets.count).lowercased()
        switch kind {
        case .sync(let source):
            let name = PhotoActions.photo(source, model).map(\.displayTitle) ?? "the focused photo"
            return "Copies the checked sections from \(name) to \(n). Unchecked sections stay as they are. One undo step."
        case .paste:
            return "Pastes the checked sections of the settings copied from \(DevelopClipboard.copiedFrom ?? "a photo") to \(n). "
                + "Paste Settings keeps using this choice. One undo step."
        }
    }

    private var applyTitle: String {
        switch kind {
        case .sync: "Sync \(PhotoActionSpec.photos(targets.count))"
        case .paste: "Paste to \(PhotoActionSpec.photos(targets.count))"
        }
    }

    private var applyHelp: String {
        sections.isEmpty ? "Check at least one section" : "Apply the checked sections (Edit > Undo reverts all photos at once)"
    }

    private func apply() {
        switch kind {
        case .sync(let source):
            Self.syncSections = sections
            PhotoActions.syncSettings(from: source, to: targets, sections: sections, model: model)
        case .paste:
            DevelopClipboard.pasteSections = sections
            PhotoActions.pasteSettings(targets, sections: sections, model: model)
        }
        dismiss()
    }

    #if DEBUG
    /// DevScript: apply with explicit sections without showing the sheet's buttons.
    static func applyForTest(_ kind: Kind, targets: [Int64], sections: Set<EditSection>, model: AppModel) {
        switch kind {
        case .sync(let source):
            syncSections = sections
            PhotoActions.syncSettings(from: source, to: targets, sections: sections, model: model)
        case .paste:
            DevelopClipboard.pasteSections = sections
            PhotoActions.pasteSettings(targets, sections: sections, model: model)
        }
    }
    #endif
}
