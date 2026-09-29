//
//  PreviewActivityView.swift
//  sloproom
//
//  Small, unobtrusive progress indicator for preview build jobs (empty when idle).
//  Place it in a toolbar / status bar: `ToolbarItem { PreviewActivityView() }`.
//

import SwiftUI

struct PreviewActivityView: View {
    private var jobs: PreviewJobs { PreviewJobs.shared }

    var body: some View {
        if let job = jobs.current {
            HStack(spacing: 6) {
                ProgressView(value: jobs.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Previews \(jobs.done) / \(jobs.total)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    jobs.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .iconHelp("Stop building previews")
            }
            .help(jobs.queued.isEmpty ? job.title : "\(job.title) (\(jobs.queued.count) more queued)")
            .fixedSize()
        }
    }
}
