//
//  PlayerPanelCoverGeometryTests.swift
//  Yattee
//
//  Regressions for the half-open cover and its transition to the pinned queue.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Player panel cover geometry")
struct PlayerPanelCoverGeometryTests {
    // iPhone 13 mini: 375x812pt, with a 50pt top and 34pt bottom safe area.
    private let geometry = PlayerPanelCoverGeometry(
        screenHeight: 728 + 50 + 34, topSafeArea: 50, headerHeight: 80, noticesHeight: 0
    )

    @Test("B shows a cover from the physical screen top to 48 percent of its height")
    func halfOpenCover() {
        let offset = geometry.detents.halfOpenOffset
        let contentScreenOrigin = 50 + 80 - offset

        #expect(offset == 130)
        #expect(contentScreenOrigin == 0)
        #expect(abs(contentScreenOrigin + geometry.coverHeight - 389.76) < 0.01)
        #expect(geometry.coverHeight > 375)
        #expect(geometry.morphProgress(at: offset - 1) < 1)
        #expect(geometry.morphProgress(at: offset) == 1)
    }

    @Test("B has compact transport followed by a 16pt gap to the grabber")
    func compactTransportAndQueue() {
        let grabberTop = geometry.contentHeight + geometry.queueTopPadding(at: 130) + 8

        #expect(abs(geometry.transportTop - 397.76) < 0.01)
        #expect(PlayerPanelCoverGeometry.transportHeight == 80)
        #expect(abs(geometry.contentHeight - 477.76) < 0.01)
        #expect(abs(grabberTop - geometry.contentHeight - 16) < 0.01)
        #expect(abs(grabberTop + 5 + 16 - 514.76) < 0.01)
    }

    @Test("The completed cover scrolls without shrinking from B through C", arguments: [CGFloat(130), 200, 350, 477.76, 600])
    func completedMorph(offset: CGFloat) {
        #expect(geometry.morphProgress(at: offset) == 1)
        #expect(abs(geometry.coverHeight - 389.76) < 0.01)
    }

    @Test("C hides all controls and preserves the queue position below the pinned header", arguments: [CGFloat(0), 60])
    func fullQueue(noticesHeight: CGFloat) {
        let geometry = PlayerPanelCoverGeometry(
            screenHeight: 812, topSafeArea: 50, headerHeight: 80, noticesHeight: noticesHeight
        )
        let offset = geometry.detents.fullQueueOffset
        let contentScreenOrigin = 130 - offset
        let noticesBottom = contentScreenOrigin + geometry.contentHeight
        let grabberTop = noticesBottom + geometry.queueTopPadding(at: offset) + 8

        #expect(abs(offset - (477.76 + noticesHeight)) < 0.01)
        #expect(abs(noticesBottom - 130) < 0.01)
        #expect(abs(grabberTop - 170) < 0.01)
        #expect(geometry.queueProgress(at: offset) == 1)
    }

    @Test("A retains its padding and a flick still advances to B")
    func normalPlayer() {
        #expect(geometry.morphProgress(at: 0) == 0)
        #expect(geometry.queueTopPadding(at: 0) == 16)
        #expect(geometry.detents.targetOffset(startOffset: 0, releaseOffset: 20, velocity: 600) == 130)
        #expect(geometry.detents.targetOffset(startOffset: 130, releaseOffset: 120, velocity: -600) == 0)
    }

    @Test("Landscape leaves space for transport and queue below the cover")
    func landscape() {
        let geometry = PlayerPanelCoverGeometry(
            screenHeight: 375, topSafeArea: 0, headerHeight: 80, noticesHeight: 0
        )
        #expect(geometry.coverHeight == 180)
        #expect(geometry.detents.halfOpenOffset == 80)
        #expect(geometry.detents.fullQueueOffset == 268)
        #expect(geometry.contentHeight + geometry.queueTopPadding(at: 80) + 8 + 5 + 16 < 375)
    }
}
