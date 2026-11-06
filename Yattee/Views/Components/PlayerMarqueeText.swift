//
//  PlayerMarqueeText.swift
//  Yattee
//
//  A single-line title that pauses before scrolling overflowing text.
//

import Foundation
import SwiftUI

@MainActor
struct PlayerMarqueeText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollingID: AnimationID?

    private let spacing: CGFloat = 40
    private let speed: CGFloat = 30

    private struct AnimationID: Equatable, Sendable {
        let text: String
        let containerWidth: CGFloat
        let textWidth: CGFloat
        let reduceMotion: Bool
    }

    private var animationID: AnimationID {
        AnimationID(text: text, containerWidth: containerWidth, textWidth: textWidth, reduceMotion: reduceMotion)
    }

    // MARK: - Layout

    var body: some View {
        let id = animationID
        let isScrolling = scrollingID == id && !reduceMotion

        Text(verbatim: text)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isScrolling ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                containerWidth = $0
            }
            .background(alignment: .leading) {
                untruncatedText
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        textWidth = $0
                    }
            }
            .overlay(alignment: .leading) {
                HStack(spacing: spacing) {
                    untruncatedText
                    untruncatedText
                }
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .animation(.linear(duration: Double((textWidth + spacing) / speed)), value: offset)
                .frame(width: containerWidth, alignment: .leading)
                .mask { edgeFade }
                .opacity(isScrolling ? 1 : 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
            .task(id: id) {
                await scroll(for: id)
            }
    }

    private var untruncatedText: some View {
        Text(verbatim: text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var edgeFade: some View {
        let edge = min(0.5, 16 / max(containerWidth, 1))
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: edge),
            .init(color: .black, location: 1 - edge),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - Animation

    private func scroll(for id: AnimationID) async {
        guard !Task.isCancelled else { return }
        resetScroll()
        guard !id.reduceMotion, id.containerWidth > 0, id.textWidth > id.containerWidth else { return }

        let distance = id.textWidth + spacing
        let duration = Double(distance / speed)

        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
                scrollingID = id
                offset = -distance
                try await Task.sleep(for: .seconds(duration))
                try Task.checkCancellation()
                resetScroll()
            }
        } catch {
            // Title, geometry and Reduce Motion changes cancel the previous loop.
        }
    }

    private func resetScroll() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            scrollingID = nil
        }
    }
}
