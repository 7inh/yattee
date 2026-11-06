//
//  PlayerPanelDetentsTests.swift
//  Yattee
//
//  Tests deterministic release resolution and continuous finger tracking.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Player panel detents")
struct PlayerPanelDetentsTests {
    private let detents = PlayerPanelDetents(normalToHalfOpenDistance: 130, halfOpenToFullQueueDistance: 350)

    @Test("Slow releases choose the nearest detent", arguments: [
        (PanelDetent.normal, CGFloat(-40), PanelDetent.normal),
        (.normal, -100, .halfOpen),
        (.normal, -140, .halfOpen),
        (.halfOpen, 40, .halfOpen),
        (.halfOpen, 100, .normal),
        (.halfOpen, -140, .halfOpen),
        (.halfOpen, -200, .fullQueue),
        (.fullQueue, 140, .fullQueue),
        (.fullQueue, 200, .halfOpen)
    ])
    func nearestDetent(start: PanelDetent, translation: CGFloat, expected: PanelDetent) {
        #expect(detents.target(from: start, translation: translation, predictedTranslation: translation) == expected)
    }

    @Test("Prediction selects the destination in both directions", arguments: [
        (PanelDetent.normal, CGFloat(-20), CGFloat(-100), PanelDetent.halfOpen),
        (.halfOpen, -20, -200, .fullQueue),
        (.halfOpen, 20, 100, .normal),
        (.fullQueue, 20, 200, .halfOpen),
        (.halfOpen, -150, 100, .normal),
        (.halfOpen, 100, -200, .fullQueue)
    ])
    func predictedRelease(start: PanelDetent, translation: CGFloat, predicted: CGFloat, expected: PanelDetent) {
        #expect(detents.target(from: start, translation: translation, predictedTranslation: predicted) == expected)
    }

    @Test("Long drags and ordinary flicks advance at most one step", arguments: [
        (PanelDetent.normal, CGFloat(-600), CGFloat(-600), PanelDetent.halfOpen),
        (.normal, -140, -350, .halfOpen),
        (.normal, -140, -419, .halfOpen),
        (.fullQueue, 600, 600, .halfOpen),
        (.fullQueue, 220, 480, .halfOpen),
        (.fullQueue, 220, 499, .halfOpen)
    ])
    func oneStep(start: PanelDetent, translation: CGFloat, predicted: CGFloat, expected: PanelDetent) {
        #expect(detents.target(from: start, translation: translation, predictedTranslation: predicted) == expected)
    }

    @Test("Only a strong flick with enough projected travel can skip B", arguments: [
        (PanelDetent.normal, CGFloat(-20), CGFloat(-600), PanelDetent.fullQueue),
        (.normal, -140, -420, .fullQueue),
        (.normal, -10, -300, .halfOpen),
        (.fullQueue, 20, 600, .normal),
        (.fullQueue, 140, 420, .normal),
        (.fullQueue, 10, 300, .halfOpen),
        // Large momentum opposite the projected destination must not skip B.
        (.normal, -800, -400, .halfOpen),
        (.fullQueue, 800, 400, .halfOpen)
    ])
    func strongFlick(start: PanelDetent, translation: CGFloat, predicted: CGFloat, expected: PanelDetent) {
        #expect(detents.target(from: start, translation: translation, predictedTranslation: predicted) == expected)
    }

    @Test("Outward drags stay at the endpoint", arguments: [CGFloat(0), 40, 500, 5000])
    func endpoints(distance: CGFloat) {
        #expect(detents.target(from: .normal, translation: distance, predictedTranslation: distance * 2) == .normal)
        #expect(detents.target(from: .fullQueue, translation: -distance, predictedTranslation: -distance * 2) == .fullQueue)
    }

    @Test("Tracking is continuous across both unequal detent intervals")
    func continuousProgress() {
        #expect(detents.progress(from: .normal, translation: -65) == 0.5)
        #expect(detents.progress(from: .normal, translation: -130) == 1)
        #expect(detents.progress(from: .normal, translation: -305) == 1.5)
        #expect(detents.progress(from: .halfOpen, translation: -350) == 2)
        #expect(detents.progress(from: .fullQueue, translation: 175) == 1.5)
        #expect(detents.progress(from: .fullQueue, translation: 415) == 0.5)
        for distance: CGFloat in [129.999, 130, 130.001, 479.999, 480, 480.001] {
            let fromA = detents.progress(from: .normal, translation: -distance)
            let fromB = detents.progress(from: .halfOpen, translation: 130 - distance)
            let fromC = detents.progress(from: .fullQueue, translation: 480 - distance)
            #expect(abs(fromA - fromB) < 0.000001)
            #expect(abs(fromA - fromC) < 0.000001)
        }
    }

    @Test("Overscroll is rubber-banded outside A and C", arguments: [CGFloat(1), 50, 500, 5000])
    func rubberBand(distance: CGFloat) {
        let beforeA = detents.progress(from: .normal, translation: distance)
        let afterC = detents.progress(from: .fullQueue, translation: -distance)
        #expect(beforeA < 0 && beforeA > -0.25)
        #expect(afterC > 2 && afterC < 2.25)
        #expect(abs(beforeA) < distance / 130)
        #expect(afterC - 2 < distance / 350)
    }

    @Test("Every release resolves to a real detent with the one-step limit")
    func exhaustiveReleaseGrid() {
        for start in PanelDetent.allCases {
            for translation: CGFloat in [-1000, -480, -140, -20, 0, 20, 140, 480, 1000] {
                for momentum: CGFloat in [-600, -279, 0, 279, 600] {
                    let target = detents.target(
                        from: start, translation: translation, predictedTranslation: translation + momentum
                    )
                    #expect(PanelDetent.allCases.contains(target))
                    if abs(momentum) < 280 {
                        #expect(abs(target.rawValue - start.rawValue) <= 1)
                    }
                }
            }
        }
    }
}
