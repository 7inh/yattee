//
//  PlayerPanelCoverGeometryTests.swift
//  Yattee
//
//  Verifies A/B/C layout without scroll content sizes or content insets.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Player panel cover geometry")
struct PlayerPanelCoverGeometryTests {
    // iPhone 13 mini: 375x812pt, with a 50pt top and 34pt bottom safe area.
    private let geometry = PlayerPanelCoverGeometry(
        screenHeight: 812, topSafeArea: 50, headerHeight: 80, noticesHeight: 0
    )

    @Test("A retains the header, square-player space and queue padding")
    func normalPlayer() {
        let layout = geometry.layout(progress: 0, normalPlayerHeight: 648)
        #expect(layout.playerOriginY == 80)
        #expect(layout.playerHeight == 648)
        #expect(layout.queueTop == 744)
        #expect(layout.queueRowsTop == 773)
        #expect(layout.morphProgress == 0)
        #expect(layout.queueProgress == 0)
        #expect(layout.coverHeaderProgress == 0)
    }

    @Test("B shows the full-bleed 48 percent cover and original compact transport", arguments: [CGFloat(400), 648, 900])
    func halfOpenCover(normalHeight: CGFloat) {
        let layout = geometry.layout(progress: 1, normalPlayerHeight: normalHeight)
        #expect(layout.playerOriginY + geometry.topSafeArea == 0)
        #expect(abs(geometry.coverHeight - 389.76) < 0.001)
        #expect(abs(geometry.transportTop - 397.76) < 0.001)
        #expect(PlayerPanelCoverGeometry.transportHeight == 80)
        #expect(abs(layout.playerHeight - 477.76) < 0.001)
        #expect(abs(layout.queueHandleTop + 50 - 493.76) < 0.001)
        #expect(abs(layout.queueRowsTop + 50 - 514.76) < 0.001)
        #expect(layout.morphProgress == 1)
        #expect(layout.coverHeaderProgress == 1)
    }

    @Test("B-to-C translates the completed cover without squeezing it", arguments: [CGFloat(1), 1.25, 1.5, 1.75, 2])
    func completedMorph(progress: CGFloat) {
        let layout = geometry.layout(progress: progress, normalPlayerHeight: 648)
        #expect(layout.morphProgress == 1)
        #expect(abs(layout.playerHeight - 477.76) < 0.001)
        #expect(abs(layout.queueProgress - (progress - 1)) < 0.001)
        let halfOpen = geometry.layout(progress: 1, normalPlayerHeight: 648)
        #expect(abs(layout.playerOriginY - halfOpen.playerOriginY + (progress - 1) * 347.76) < 0.001)
    }

    @Test("C places the queue below the pinned card regardless of notices or normal height", arguments: [CGFloat(0), 60, 150])
    func fullQueue(noticesHeight: CGFloat) {
        let geometry = PlayerPanelCoverGeometry(
            screenHeight: 812, topSafeArea: 50, headerHeight: 80, noticesHeight: noticesHeight
        )
        for normalHeight: CGFloat in [400, 648, 900] {
            let layout = geometry.layout(progress: 2, normalPlayerHeight: normalHeight)
            #expect(abs(layout.playerOriginY + layout.playerHeight - 80) < 0.001)
            #expect(abs(layout.queueTop - 72) < 0.001)
            #expect(abs(layout.queueHandleTop - 80) < 0.001)
            #expect(abs(layout.queueRowsTop - 93) < 0.001)
            #expect(layout.queueProgress == 1)
            #expect(layout.coverHeaderProgress == 0)
        }
    }

    @Test("Gesture distances match the visual movement between detents")
    func layoutAndGestureAgree() {
        let distances = geometry.detents
        #expect(distances.normalToHalfOpenDistance == 130)
        #expect(abs(distances.halfOpenToFullQueueDistance - 347.76) < 0.001)
        let progress = distances.progress(from: .normal, translation: -130)
        #expect(geometry.layout(progress: progress, normalPlayerHeight: 648).morphProgress == 1)
        #expect(distances.target(from: .normal, translation: -140, predictedTranslation: -140) == .halfOpen)
        #expect(distances.target(from: .fullQueue, translation: 200, predictedTranslation: 200) == .halfOpen)
    }

    @Test("Landscape preserves B's transport and C's queue position")
    func landscape() {
        let geometry = PlayerPanelCoverGeometry(
            screenHeight: 375, topSafeArea: 0, headerHeight: 80, noticesHeight: 0
        )
        let halfOpen = geometry.layout(progress: 1, normalPlayerHeight: 295)
        let fullQueue = geometry.layout(progress: 2, normalPlayerHeight: 295)
        #expect(geometry.coverHeight == 180)
        #expect(halfOpen.playerOriginY == 0)
        #expect(halfOpen.playerHeight == 268)
        #expect(halfOpen.queueRowsTop < 375)
        #expect(fullQueue.queueTop == 72)
        #expect(fullQueue.queueHandleTop == 80)
        #expect(fullQueue.queueRowsTop == 93)
    }
}
