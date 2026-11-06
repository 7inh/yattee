//
//  PlayerPanelDetents.swift
//  Yattee
//
//  Resolves gesture-driven player detents independently of queue content.
//

import Foundation

enum PanelDetent: Int, CaseIterable, Codable, Hashable, Sendable {
    case normal
    case halfOpen
    case fullQueue
}

struct PlayerPanelDetents: Hashable, Sendable {
    let normalToHalfOpenDistance: CGFloat
    let halfOpenToFullQueueDistance: CGFloat

    private var firstDistance: CGFloat { max(1, normalToHalfOpenDistance) }
    private var secondDistance: CGFloat { max(1, halfOpenToFullQueueDistance) }

    // MARK: - Finger Tracking

    /// Upward translations open the panel. Each interval uses its own distance.
    func progress(from start: PanelDetent, translation: CGFloat) -> CGFloat {
        let progress = unboundedProgress(from: start, translation: translation)
        if progress < 0 { return -rubberBand(-progress) }
        if progress > 2 { return 2 + rubberBand(progress - 2) }
        return progress
    }

    private func unboundedProgress(from start: PanelDetent, translation: CGFloat) -> CGFloat {
        let startDistance: CGFloat
        switch start {
        case .normal: startDistance = 0
        case .halfOpen: startDistance = firstDistance
        case .fullQueue: startDistance = firstDistance + secondDistance
        }
        let distance = startDistance - translation
        if distance <= firstDistance { return distance / firstDistance }
        return 1 + (distance - firstDistance) / secondDistance
    }

    private func rubberBand(_ excess: CGFloat) -> CGFloat {
        0.25 * excess / (1 + excess)
    }

    // MARK: - Release Resolution

    func target(
        from start: PanelDetent, translation: CGFloat, predictedTranslation: CGFloat
    ) -> PanelDetent {
        let projectedProgress = unboundedProgress(from: start, translation: predictedTranslation)
        let nearest = Int(min(2, max(0, projectedProgress)).rounded())
        let momentum = predictedTranslation - translation
        let direction = nearest - start.rawValue
        // Prediction already includes velocity. Only substantial momentum in
        // the destination's direction may skip B; a long slow drag never does.
        let isStrongFlick = abs(momentum) >= 280 && CGFloat(direction) * momentum < 0
        let step = isStrongFlick ? 2 : 1
        let target = min(start.rawValue + step, max(start.rawValue - step, nearest))
        return PanelDetent(rawValue: target) ?? start
    }
}
