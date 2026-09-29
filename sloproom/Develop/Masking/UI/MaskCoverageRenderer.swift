//
//  MaskCoverageRenderer.swift
//  sloproom
//
//  Renders the red "O" overlay (selected mask coverage in displayed space) off-main.
//  One render in flight, latest request wins — same pattern as DevelopSession.
//

import Foundation
import CoreGraphics
import Observation

@Observable
final class MaskCoverageRenderer {
    struct Request: Equatable {
        var mask: Mask
        var geometry: Geometry
        var fullSize: CGSize
        var targetSize: CGSize
    }

    private(set) var image: CGImage?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var generation = 0

    func request(_ r: Request) {
        if inFlight { pending = r; return }
        inFlight = true
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = MaskRenderer.coverageImage(for: r.mask, geometry: r.geometry, fullSize: r.fullSize, targetSize: r.targetSize)
            await self?.finished(img, generation: gen)
        }
    }

    func clear() {
        generation += 1
        pending = nil
        image = nil
    }

    private func finished(_ img: CGImage?, generation gen: Int) {
        inFlight = false
        if gen == generation { image = img }
        if let next = pending {
            pending = nil
            request(next)
        }
    }
}
