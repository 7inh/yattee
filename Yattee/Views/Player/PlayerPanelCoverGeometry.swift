//
//  PlayerPanelCoverGeometry.swift
//  Yattee
//
//  Pure layout for the normal player, full-bleed cover and pinned queue.
//

import Foundation

struct PlayerPanelCoverGeometry: Equatable, Sendable {
    static let transportSpacing: CGFloat = 8
    static let transportHeight: CGFloat = 80
    static let queueHandleHeight: CGFloat = 5
    static let queueHandleTopSpacing: CGFloat = 8

    let screenHeight: CGFloat
    let topSafeArea: CGFloat
    let headerHeight: CGFloat
    let noticesHeight: CGFloat

    var coverHeight: CGFloat { screenHeight * 0.48 }
    var transportTop: CGFloat { coverHeight + Self.transportSpacing }
    var contentHeight: CGFloat { transportTop + Self.transportHeight + noticesHeight }
    var detents: PlayerPanelDetents {
        PlayerPanelDetents(
            normalToHalfOpenDistance: headerHeight + topSafeArea,
            halfOpenToFullQueueDistance: max(1, contentHeight - headerHeight - topSafeArea)
        )
    }

    struct PanelLayout: Equatable, Sendable {
        let morphProgress: CGFloat
        let queueProgress: CGFloat
        let playerOriginY: CGFloat
        let playerHeight: CGFloat
        let queueTop: CGFloat
        let coverHeaderProgress: CGFloat

        var queueHandleTop: CGFloat { queueTop + PlayerPanelCoverGeometry.queueHandleTopSpacing }
        var queueHandleBottomSpacing: CGFloat { 16 - 8 * queueProgress }
        var queueRowsTop: CGFloat {
            queueHandleTop + PlayerPanelCoverGeometry.queueHandleHeight + queueHandleBottomSpacing
        }
    }

    /// Coordinates are relative to the top safe area. The queue's measured
    /// content size and scroll geometry never participate in panel layout.
    func layout(progress: CGFloat, normalPlayerHeight: CGFloat) -> PanelLayout {
        let morph = min(1, max(0, progress))
        let queue = min(1, max(0, progress - 1))
        let playerHeight = normalPlayerHeight + (contentHeight - normalPlayerHeight) * morph
        let overshoot = progress < 0 ? -progress * detents.normalToHalfOpenDistance
            : -max(0, progress - 2) * detents.halfOpenToFullQueueDistance
        let origin = headerHeight - morph * (headerHeight + topSafeArea)
            - queue * detents.halfOpenToFullQueueDistance + overshoot
        // Preserve A/B. In C the card ends 8pt before the header's bottom;
        // start the queue there so its top padding leaves an 8pt grabber gap.
        let queuePadding = 16 - 8 * morph - 16 * queue
        let coverHeaderProgress = morph * min(1, max(0, (origin + coverHeight) / max(1, headerHeight)))
        return PanelLayout(
            morphProgress: morph, queueProgress: queue,
            playerOriginY: origin, playerHeight: playerHeight,
            queueTop: origin + playerHeight + queuePadding,
            coverHeaderProgress: coverHeaderProgress
        )
    }
}
