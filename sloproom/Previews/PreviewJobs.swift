//
//  PreviewJobs.swift
//  sloproom
//
//  Observable state of preview build jobs (one runs at a time, others queue) and per-photo
//  "revisions" that tell `ThumbnailView` to reload after previews were discarded/regenerated.
//  Start jobs with `PreviewService.shared.build(photoIDs:levels:)` or the helpers below.
//

import Foundation
import Observation

@MainActor
@Observable
final class PreviewJobs {
    static let shared = PreviewJobs()

    struct Job: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let photoIDs: [Int64]
        let levels: [PreviewLevel]
    }

    /// The running job and its progress (nil when idle).
    private(set) var current: Job?
    private(set) var done = 0
    private(set) var total = 0
    /// Items that could not be generated (offline / unreadable) in the current job.
    private(set) var failed = 0
    private(set) var queued: [Job] = []

    var isBusy: Bool { current != nil }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// Global revision (clean cache, settings change) + per-photo revisions (discard/regenerate).
    private(set) var epoch = 0
    private(set) var photoRevisions: [Int64: Int] = [:]
    func revision(for photoID: Int64) -> Int { epoch &+ (photoRevisions[photoID] ?? 0) }

    private var runner: Task<Void, Never>?

    // MARK: - Jobs

    func enqueue(title: String, photoIDs: [Int64], levels: [PreviewLevel]) {
        guard !photoIDs.isEmpty, !levels.isEmpty else { return }
        queued.append(Job(title: title, photoIDs: photoIDs, levels: levels))
        startNextIfIdle()
    }

    /// Cancels the running job and everything queued.
    func cancel() {
        queued.removeAll()
        runner?.cancel()
    }

    /// Menu / settings helpers.
    func buildStandard(for photoIDs: [Int64]) {
        enqueue(title: "Building standard previews", photoIDs: photoIDs, levels: [.thumbnail, .standard])
    }

    func buildAll() {
        guard let catalog = PreviewService.shared.catalog, let ids = try? catalog.allPhotoIDs() else { return }
        enqueue(title: "Building previews for all photos", photoIDs: ids, levels: [.thumbnail, .standard])
    }

    func regenerate(_ photoIDs: [Int64]) {
        PreviewService.shared.discard(photoIDs: photoIDs)
        enqueue(title: "Regenerating previews", photoIDs: photoIDs, levels: [.thumbnail, .standard])
    }

    func regenerateAll() {
        cancel()
        PreviewService.shared.discardAll()
        buildAll()
    }

    func discard(_ photoIDs: [Int64]) {
        PreviewService.shared.discard(photoIDs: photoIDs)
    }

    func discardAll() {
        cancel()
        PreviewService.shared.discardAll()
    }

    private func startNextIfIdle() {
        guard current == nil, !queued.isEmpty else { return }
        let job = queued.removeFirst()
        current = job
        done = 0
        failed = 0
        total = job.photoIDs.count * job.levels.count
        runner = Task { [weak self] in
            await Self.run(job) { done, failed in
                self?.done = done
                self?.failed = failed
            }
            self?.finish()
        }
    }

    private func finish() {
        current = nil
        runner = nil
        startNextIfIdle()
        if current == nil {
            let service = PreviewService.shared
            Task.detached(priority: .utility) { service.pruneIfNeeded() }
        }
    }

    /// Runs off the main actor; reports progress at most ~10×/s.
    @concurrent
    private static func run(_ job: Job, progress: @escaping @MainActor (Int, Int) -> Void) async {
        let service = PreviewService.shared
        guard let catalog = service.catalog else { return }
        let inFlight = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var done = 0, failed = 0
        var lastReport = Date.distantPast
        for chunk in stride(from: 0, to: job.photoIDs.count, by: 200) {
            if Task.isCancelled { break }
            let ids = Array(job.photoIDs[chunk..<min(chunk + 200, job.photoIDs.count)])
            let photos = (try? catalog.photos(ids: ids)) ?? []
            done += (ids.count - photos.count) * job.levels.count // removed meanwhile
            let items = job.levels.flatMap { level in photos.map { (level, $0) } } // thumbnails first
            await withTaskGroup(of: Bool.self) { group in
                var next = 0
                func add() {
                    let (level, photo) = items[next]
                    next += 1
                    group.addTask { await service.ensureOnDisk(photo, level: level) }
                }
                while next < min(inFlight, items.count) { add() }
                while let ok = await group.next() {
                    done += 1
                    if !ok { failed += 1 }
                    if Task.isCancelled { group.cancelAll(); continue }
                    if next < items.count { add() }
                    if Date().timeIntervalSince(lastReport) > 0.1 {
                        lastReport = Date()
                        let (d, f) = (done, failed)
                        await progress(d, f)
                    }
                }
            }
        }
        let (d, f) = (done, failed)
        await progress(d, f)
    }

    // MARK: - Revisions (called from any thread)

    nonisolated static func notifyChanged(_ photoIDs: Set<Int64>) {
        Task { @MainActor in
            for id in photoIDs { shared.photoRevisions[id, default: 0] += 1 }
        }
    }

    nonisolated static func notifyAllChanged() {
        Task { @MainActor in shared.epoch += 1 }
    }
}
