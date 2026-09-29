//
//  PreviewCommands.swift
//  sloproom
//
//  Library > Previews ▸ menu. Add to the App scene with
//      .commands { SloproomCommands(model: model); PreviewCommands(model: model) }
//  If another feature also creates a "Library" menu, embed `PreviewMenu(model: model)` in it
//  instead (it is the "Previews" submenu).
//

import AppKit
import SwiftUI

struct PreviewCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Library") {
            PreviewMenu(model: model)
        }
    }
}

/// The "Previews" submenu. Selection commands act on `model.actionTargetIDs`.
struct PreviewMenu: View {
    let model: AppModel
    private var jobs: PreviewJobs { PreviewJobs.shared }

    var body: some View {
        // Targets are read when the item is chosen: menu bar Commands aren't re-rendered when the
        // selection changes, so a `.disabled(targets.isEmpty)` computed here goes stale.
        Menu("Previews") {
            Button("Build Standard Previews for Selection") { jobs.buildStandard(for: model.actionTargetIDs) }
            Button("Build Standard Previews for All Photos") { jobs.buildAll() }
            Divider()
            Button("Regenerate Previews for Selection") { jobs.regenerate(model.actionTargetIDs) }
            Button("Discard Previews for Selection") { jobs.discard(model.actionTargetIDs) }
            Button("Discard All Previews (Clean Cache)…") { confirmDiscardAll() }
            if jobs.isBusy {
                Divider()
                Button("Stop Building Previews") { jobs.cancel() }
            }
        }
    }

    private func confirmDiscardAll() {
        let alert = NSAlert()
        alert.messageText = "Discard all previews?"
        alert.informativeText = "All cached thumbnails and standard previews are deleted. They are regenerated when photos are shown again."
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { jobs.discardAll() }
    }
}
