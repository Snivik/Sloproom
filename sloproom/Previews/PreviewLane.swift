//
//  PreviewLane.swift
//  sloproom
//
//  A small prioritized work queue with a fixed number of worker threads:
//  - requests for the same key share one job (coalescing),
//  - `.visible` jobs run before `.background` ones, newest first (the cells that just scrolled
//    into view), and background jobs never take the last worker,
//  - cancelling the awaiting Task removes its request; a job nobody waits for any more is
//    dropped before it starts (cells scrolled away cost nothing).
//

import Foundation

nonisolated enum PreviewPriority: Int, Sendable, Comparable {
    /// Build jobs, eager regeneration after edits, prefetch.
    case background = 0
    /// A view is waiting for it right now.
    case visible = 1

    static func < (a: PreviewPriority, b: PreviewPriority) -> Bool { a.rawValue < b.rawValue }
}

nonisolated final class PreviewLane<Value: Sendable>: @unchecked Sendable {
    private final class Job {
        let key: String
        var priority: PreviewPriority
        var sequence: UInt64
        var waiters: [UInt64: CheckedContinuation<Value?, Never>] = [:]
        let work: @Sendable () -> Value

        init(key: String, priority: PreviewPriority, sequence: UInt64, work: @escaping @Sendable () -> Value) {
            self.key = key
            self.priority = priority
            self.sequence = sequence
            self.work = work
        }
    }

    let maxWorkers: Int
    private let maxBackgroundWorkers: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [String: Job] = [:]
    private var running: [String: Job] = [:]
    /// Waiters whose Task was cancelled before they were registered.
    private var cancelledEarly: Set<UInt64> = []
    private var counter: UInt64 = 0
    private var activeWorkers = 0
    private var activeBackground = 0

    init(name: String, workers: Int, qos: DispatchQoS = .userInitiated) {
        maxWorkers = max(1, workers)
        maxBackgroundWorkers = max(1, maxWorkers - 1)
        queue = DispatchQueue(label: name, qos: qos, attributes: .concurrent)
    }

    /// Runs `work` (or joins the job already queued/running for `key`). Returns nil if the
    /// calling Task was cancelled before the job produced a value.
    func run(key: String, priority: PreviewPriority, work: @escaping @Sendable () -> Value) async -> Value? {
        let waiter = nextID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Value?, Never>) in
                lock.lock()
                if cancelledEarly.remove(waiter) != nil {
                    lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                if let job = running[key] {
                    job.waiters[waiter] = cont
                } else if let job = pending[key] {
                    job.waiters[waiter] = cont
                    if priority > job.priority { job.priority = priority }
                    job.sequence = nextIDLocked() // most recently wanted first
                } else {
                    let job = Job(key: key, priority: priority, sequence: nextIDLocked(), work: work)
                    job.waiters[waiter] = cont
                    pending[key] = job
                }
                startWorkersLocked()
                lock.unlock()
            }
        } onCancel: {
            cancel(waiter: waiter, key: key)
        }
    }

    /// Number of jobs waiting to start (for diagnostics / tests).
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    // MARK: - Internals

    private func nextID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return nextIDLocked()
    }

    private func nextIDLocked() -> UInt64 {
        counter &+= 1
        return counter
    }

    private func cancel(waiter: UInt64, key: String) {
        lock.lock()
        let job = pending[key] ?? running[key]
        guard let job, let cont = job.waiters.removeValue(forKey: waiter) else {
            cancelledEarly.insert(waiter)
            lock.unlock()
            return
        }
        if job.waiters.isEmpty, pending[key] === job { pending[key] = nil }
        lock.unlock()
        cont.resume(returning: nil)
    }

    private func startWorkersLocked() {
        let wanted = min(maxWorkers, pending.count)
        while activeWorkers < wanted {
            activeWorkers += 1
            queue.async { self.workerLoop() }
        }
    }

    /// Best pending job this worker may take: visible before background, newest first.
    private func takeNextLocked() -> Job? {
        var best: Job?
        for job in pending.values {
            if job.priority == .background && activeBackground >= maxBackgroundWorkers { continue }
            if let b = best, (b.priority, b.sequence) >= (job.priority, job.sequence) { continue }
            best = job
        }
        guard let best else { return nil }
        pending[best.key] = nil
        running[best.key] = best
        if best.priority == .background { activeBackground += 1 }
        return best
    }

    private func workerLoop() {
        while true {
            lock.lock()
            guard let job = takeNextLocked() else {
                activeWorkers -= 1
                lock.unlock()
                return
            }
            lock.unlock()

            let value = autoreleasepool { job.work() }

            lock.lock()
            running[job.key] = nil
            if job.priority == .background { activeBackground -= 1 }
            let waiters = job.waiters
            job.waiters = [:]
            if cancelledEarly.count > 4096 { cancelledEarly.removeAll() }
            startWorkersLocked()
            lock.unlock()
            for cont in waiters.values { cont.resume(returning: value) }
        }
    }
}
