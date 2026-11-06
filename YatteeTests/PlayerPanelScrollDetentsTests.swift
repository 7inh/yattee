//
//  PlayerPanelScrollDetentsTests.swift
//  Yattee
//
//  Tests player detent selection and the handoff to freely scrolling queue content.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Player panel scroll detents")
struct PlayerPanelScrollDetentsTests {
    private let detents = PlayerPanelScrollDetents(halfOpenOffset: 140, fullQueueOffset: 500)

    @Test("Slow releases snap to the nearest detent", arguments: [
        [CGFloat(30), 0], [100, 140], [220, 140], [420, 500]
    ])
    func nearestDetent(sample: [CGFloat]) {
        #expect(detents.targetOffset(startOffset: 140, releaseOffset: sample[0], velocity: 0) == sample[1])
    }

    @Test("Flicks advance one detent in their direction", arguments: [
        [CGFloat(0), 20, 600, 140],
        [140, 160, 600, 500],
        [500, 480, -600, 140],
        [140, 120, -600, 0],
        [0, 25, 249, 0]
    ])
    func flickDirection(sample: [CGFloat]) {
        #expect(detents.targetOffset(startOffset: sample[0], releaseOffset: sample[1], velocity: sample[2]) == sample[3])
    }

    @Test("Queue content scrolls freely beyond the full queue detent")
    func freeQueueScrolling() {
        #expect(detents.targetOffset(startOffset: 500, releaseOffset: 540, velocity: 600) == nil)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 650, velocity: -600) == nil)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 950, velocity: 0) == nil)
    }

    @Test("Returning from within the queue stops at its top before collapsing")
    func queueBoundary() {
        #expect(detents.queueTargetOffset(startOffset: 800, proposedOffset: 100) == 500)
        #expect(detents.queueTargetOffset(startOffset: 800, proposedOffset: 650) == 650)
        #expect(detents.queueTargetOffset(startOffset: 500, proposedOffset: 100) == 500)
        #expect(detents.queueTargetOffset(startOffset: 140, proposedOffset: 100) == 100)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 300, velocity: -600) == 500)
        #expect(detents.targetOffset(startOffset: 500, releaseOffset: 480, velocity: -600) == 140)
    }

    @Test("A downward drag at the player top remains available for dismissal")
    func topDismissal() {
        #expect(detents.targetOffset(startOffset: 0, releaseOffset: -40, velocity: -600) == nil)
        #expect(detents.targetOffset(startOffset: 0, releaseOffset: 0, velocity: 0) == nil)
    }
}
