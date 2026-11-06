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

    @Test("Flicks advance to the next detent in either direction", arguments: [
        [CGFloat(0), 20, 600, 140],
        [140, 160, 600, 500],
        [500, 480, -600, 140],
        [140, 120, -600, 0],
        [0, 25, 249, 0]
    ])
    func flickDirection(sample: [CGFloat]) {
        #expect(detents.targetOffset(startOffset: sample[0], releaseOffset: sample[1], velocity: sample[2]) == sample[3])
    }

    @Test("Long drags and fast flicks can pass the half-open detent", arguments: [
        [CGFloat(500), 100, -600, 0],
        [500, 480, -2400, 0],
        [0, 450, 600, 500],
        [0, 20, 2400, 500]
    ])
    func passingHalfOpen(sample: [CGFloat]) {
        #expect(detents.targetOffset(startOffset: sample[0], releaseOffset: sample[1], velocity: sample[2]) == sample[3])
    }

    @Test("Downward drags from C can collapse to B or A", arguments: [
        [CGFloat(500), 300, 0, 140],
        [500, 250, 0, 140],
        [500, 50, 0, 0],
        [500.5, 300, 0, 140],
        [499.5, 300, 0, 140]
    ])
    func collapsingFullQueue(sample: [CGFloat]) {
        #expect(detents.targetOffset(startOffset: sample[0], releaseOffset: sample[1], velocity: sample[2]) == sample[3])
    }

    @Test("Downward drags from B can always target A", arguments: [
        [CGFloat(140), -60, 0], // A 200pt drag from B, before top-edge clamping.
        [140, 0, 0],
        [140, 40, 0],
        [140, 69, 0],
        [140.5, 0, 0],
        [139.5, 0, 0],
        [140, 120, -600]
    ])
    func collapsingHalfOpen(sample: [CGFloat]) {
        #expect(detents.targetOffset(
            startOffset: sample[0], releaseOffset: sample[1], velocity: sample[2], maximumOffset: 500
        ) == 0)
    }

    @Test("Queues add only the bottom filler needed to reach C", arguments: [
        (0, CGFloat(485)), (1, 429), (3, 317), (16, 0)
    ])
    func queueBottomFiller(queueCount: Int, expectedFillerHeight: CGFloat) {
        let viewportHeight = PlayerPanelScrollDetents.viewportHeight(containerHeight: 728, topInset: 80, bottomInset: 34)
        let geometry = PlayerPanelCoverGeometry(screenHeight: 812, topSafeArea: 50, headerHeight: 80, noticesHeight: 0)
        let detents = geometry.detents
        // The current row remains visible with zero upcoming items. Include
        // C's top padding, grabber, row spacing and normal 16pt bottom inset.
        let rowsHeight = CGFloat(queueCount + 1) * 52 + CGFloat(queueCount) * 4
        let naturalContentHeight = geometry.contentHeight + geometry.queueTopPadding(at: detents.fullQueueOffset)
            + 8 + 5 + 16 + rowsHeight + 16
        let fillerHeight = detents.bottomFillerHeight(naturalContentHeight: naturalContentHeight, viewportHeight: viewportHeight)
        let contentHeight = naturalContentHeight + fillerHeight
        let maximumOffset = PlayerPanelScrollDetents.maximumOffset(contentHeight: contentHeight, viewportHeight: viewportHeight)

        #expect(viewportHeight == 614)
        #expect(abs(fillerHeight - expectedFillerHeight) < 0.001)
        #expect(maximumOffset >= detents.fullQueueOffset)
        #expect(PlayerPanelScrollDetents.clampedOffset(detents.fullQueueOffset, maximumOffset: maximumOffset) == detents.fullQueueOffset)
        #expect(detents.targetOffset(
            startOffset: detents.halfOpenOffset, releaseOffset: detents.halfOpenOffset + 20,
            velocity: 600, maximumOffset: maximumOffset
        ) == detents.fullQueueOffset)
        if queueCount < 16 {
            #expect(abs(maximumOffset - detents.fullQueueOffset) < 0.001)
        } else {
            #expect(contentHeight == naturalContentHeight)
            #expect(maximumOffset + viewportHeight == naturalContentHeight)
        }
    }

    @Test("B keeps the same cover and scroll coordinate for every queue length", arguments: [0, 1, 3, 16])
    func halfOpenLayoutWithQueue(queueCount: Int) {
        let viewportHeight: CGFloat = 614
        let geometry = PlayerPanelCoverGeometry(screenHeight: 812, topSafeArea: 50, headerHeight: 80, noticesHeight: 0)
        let detents = geometry.detents
        let rowsHeight = CGFloat(queueCount + 1) * 52 + CGFloat(queueCount) * 4
        let naturalContentHeight = geometry.contentHeight + geometry.queueTopPadding(at: detents.halfOpenOffset)
            + 8 + 5 + 16 + rowsHeight + 16
        let fillerHeight = detents.bottomFillerHeight(naturalContentHeight: naturalContentHeight, viewportHeight: viewportHeight)
        let maximumOffset = PlayerPanelScrollDetents.maximumOffset(
            contentHeight: naturalContentHeight + fillerHeight, viewportHeight: viewportHeight
        )
        let offset = PlayerPanelScrollDetents.clampedOffset(detents.halfOpenOffset, maximumOffset: maximumOffset)

        #expect(offset == 130)
        #expect(maximumOffset >= detents.fullQueueOffset)
        #expect(geometry.morphProgress(at: offset) == 1)
        #expect(geometry.topSafeArea + geometry.headerHeight - offset == 0)
        #expect(abs(geometry.coverHeight - 389.76) < 0.001)
        #expect(detents.targetOffset(
            startOffset: 0, releaseOffset: 20, velocity: 600, maximumOffset: maximumOffset
        ) == detents.halfOpenOffset)
        #expect(detents.targetOffset(
            startOffset: detents.halfOpenOffset, releaseOffset: detents.halfOpenOffset,
            velocity: 0, maximumOffset: maximumOffset
        ) == detents.halfOpenOffset)
        #expect(queueCount < 16 ? fillerHeight > 0 : fillerHeight == 0)
    }

    @Test("Long queues stop at the last row plus their bottom inset")
    func longQueueScrollRange() {
        let viewportHeight: CGFloat = 614
        let queueHeight: CGFloat = 1200 // Includes the normal queue padding.
        let naturalContentHeight = 500 + queueHeight
        let fillerHeight = detents.bottomFillerHeight(naturalContentHeight: naturalContentHeight, viewportHeight: viewportHeight)
        let contentHeight = naturalContentHeight + fillerHeight
        let maximumOffset = PlayerPanelScrollDetents.maximumOffset(contentHeight: contentHeight, viewportHeight: viewportHeight)

        #expect(fillerHeight == 0)
        #expect(maximumOffset == 1086)
        #expect(PlayerPanelScrollDetents.clampedOffset(840, maximumOffset: maximumOffset) == 840)
        #expect(PlayerPanelScrollDetents.clampedOffset(1500, maximumOffset: maximumOffset) == maximumOffset)
        #expect(maximumOffset + viewportHeight == contentHeight)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 950, velocity: 600, maximumOffset: maximumOffset) == nil)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 1200, velocity: 600, maximumOffset: maximumOffset) == maximumOffset)
    }

    @Test("Snaps and queue overscroll respect the maximum offset", arguments: [
        [CGFloat(500), 840, 600, 500, 500],
        [500, 840, 0, 500, 500],
        [500, 480, -600, 500, 140],
        [140, 160, 600, 300, 300],
        [0, 20, 2400, 100, 100]
    ])
    func clampedTargets(sample: [CGFloat]) {
        #expect(detents.targetOffset(
            startOffset: sample[0], releaseOffset: sample[1], velocity: sample[2], maximumOffset: sample[3]
        ) == sample[4])
    }

    @Test("Small content and excessive insets cannot produce negative scroll ranges")
    func nonnegativeScrollRange() {
        #expect(PlayerPanelScrollDetents.viewportHeight(containerHeight: 100, topInset: 80, bottomInset: 34) == 0)
        #expect(PlayerPanelScrollDetents.maximumOffset(contentHeight: 100, viewportHeight: 614) == 0)
        #expect(PlayerPanelScrollDetents.clampedOffset(-40, maximumOffset: 500) == 0)
        #expect(PlayerPanelScrollDetents.clampedOffset(40, maximumOffset: 0) == 0)
    }

    @Test("Queue content scrolls freely beyond the full queue detent")
    func freeQueueScrolling() {
        #expect(detents.targetOffset(startOffset: 500, releaseOffset: 540, velocity: 600) == nil)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 650, velocity: -600) == nil)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 950, velocity: 0) == nil)
    }

    @Test("A drag from inside the queue can continue through C into the panel")
    func queueBoundary() {
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 500, velocity: 0) == 500)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 480, velocity: -600) == 140)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 300, velocity: 0) == 140)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 300, velocity: -600) == 140)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 50, velocity: -600) == 0)
    }

    @Test("Queue momentum settling between detents snaps to the nearest one")
    func queueMomentum() {
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 650, velocity: 0) == nil)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 420, velocity: 0) == 500)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 220, velocity: 0) == 140)
        #expect(detents.targetOffset(startOffset: 800, releaseOffset: 30, velocity: 0) == 0)
    }

    @Test("A downward drag at the player top remains available for dismissal")
    func topDismissal() {
        #expect(detents.targetOffset(startOffset: 0, releaseOffset: -40, velocity: -600) == nil)
        #expect(detents.targetOffset(startOffset: 0, releaseOffset: 0, velocity: 0) == nil)
        #expect(detents.targetOffset(startOffset: 140, releaseOffset: -40, velocity: -600) == 0)
        #expect(detents.targetOffset(startOffset: 500, releaseOffset: -40, velocity: -600) == 0)
    }

    @Test("Dismissal requires A and a gesture that began at A")
    func dismissalEligibility() {
        #expect(PlayerPanelScrollDetents.allowsDismissal(offset: 0, gestureStartOffset: nil))
        #expect(PlayerPanelScrollDetents.allowsDismissal(offset: 0, gestureStartOffset: 0))
        #expect(PlayerPanelScrollDetents.allowsDismissal(offset: -40, gestureStartOffset: 0))
        #expect(!PlayerPanelScrollDetents.allowsDismissal(offset: 140, gestureStartOffset: nil))
        #expect(!PlayerPanelScrollDetents.allowsDismissal(offset: 500, gestureStartOffset: nil))
        #expect(!PlayerPanelScrollDetents.allowsDismissal(offset: 0, gestureStartOffset: 140))
        #expect(!PlayerPanelScrollDetents.allowsDismissal(offset: 0, gestureStartOffset: 500))
        #expect(!PlayerPanelScrollDetents.allowsDismissal(offset: -40, gestureStartOffset: 800))
    }
}
