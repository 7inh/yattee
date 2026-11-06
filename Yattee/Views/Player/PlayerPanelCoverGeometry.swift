//
//  PlayerPanelCoverGeometry.swift
//  Yattee
//
//  Keeps the half-open cover and queue detents in one scroll coordinate space.
//

import Foundation

struct PlayerPanelCoverGeometry: Equatable, Sendable {
    static let transportSpacing: CGFloat = 8
    static let transportHeight: CGFloat = 80

    let screenHeight: CGFloat
    let topSafeArea: CGFloat
    let headerHeight: CGFloat
    let noticesHeight: CGFloat

    // Include both safe areas in screenHeight; the cover extends behind the
    // status bar and can be taller than the screen is wide on a small iPhone.
    var coverHeight: CGFloat { screenHeight * 0.48 }

    // The completed cover starts at content y=0. Scrolling away the reserved
    // header and top safe area therefore puts its top at physical screen y=0.
    var halfOpenOffset: CGFloat { headerHeight + topSafeArea }
    var transportTop: CGFloat { coverHeight + Self.transportSpacing }
    var contentHeight: CGFloat { transportTop + Self.transportHeight + noticesHeight }
    var detents: PlayerPanelScrollDetents {
        PlayerPanelScrollDetents(
            halfOpenOffset: halfOpenOffset,
            fullQueueOffset: max(halfOpenOffset, contentHeight)
        )
    }

    func morphProgress(at offset: CGFloat) -> CGFloat {
        min(1, max(0, offset / max(1, halfOpenOffset)))
    }

    func queueProgress(at offset: CGFloat) -> CGFloat {
        min(1, max(0, (offset - halfOpenOffset) / max(1, detents.fullQueueOffset - halfOpenOffset)))
    }

    func queueTopPadding(at offset: CGFloat) -> CGFloat {
        // A keeps its original 16pt padding. B has 8pt plus the grabber's 8pt
        // inset. At C, 32pt restores the queue's original spacing below the
        // pinned header, including the removed 16pt player bottom padding.
        16 - 8 * morphProgress(at: offset) + 24 * queueProgress(at: offset)
    }
}
