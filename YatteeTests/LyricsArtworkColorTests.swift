//
//  LyricsArtworkColorTests.swift
//  YatteeTests
//
//  Verifies artwork sampling, white-text contrast, and per-video caching.
//

import Foundation
import CoreGraphics
import Testing

@testable import Yattee

@Suite("Lyrics artwork backgrounds")
struct LyricsArtworkColorTests {
    @Test("Bright and saturated artwork maintains at least 4.5:1 white contrast")
    func whiteContrast() {
        for red in stride(from: 0.0, through: 1.0, by: 0.2) {
            for green in stride(from: 0.0, through: 1.0, by: 0.2) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.2) {
                    let color = LyricsArtworkColor.darkened(red: red, green: green, blue: blue)
                    #expect(1.05 / (color.luminance + 0.05) >= 4.5)
                    #expect(color.red <= red * 0.65)
                    #expect(color.green <= green * 0.65)
                    #expect(color.blue <= blue * 0.65)
                }
            }
        }
        #expect(1.05 / (LyricsArtworkColor.fallback.luminance + 0.05) >= 4.5)
    }

    @Test("Downscaled area sampling incorporates both halves of the thumbnail")
    func averageArtwork() async throws {
        let context = try makeContext()
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 128, y: 0, width: 128, height: 128))
        let image = try #require(context.makeImage())
        let color = await LyricsArtworkColorCache().color(for: "two-colors", image: image)
        #expect(color.red > 0.1)
        #expect(color.blue > 0.1)
        #expect(abs(color.red - color.blue) < 0.01)
        #expect(color.green < 0.01)
        #expect(1.05 / (color.luminance + 0.05) >= 4.5)
    }

    @Test("Caches the sampled color per video ID")
    func cachesPerVideo() async throws {
        let context = try makeContext()
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        let red = try #require(context.makeImage())
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        let blue = try #require(context.makeImage())
        let cache = LyricsArtworkColorCache()
        let first = await cache.color(for: "first", image: red)
        let cached = await cache.color(for: "first", image: blue)
        let second = await cache.color(for: "second", image: blue)
        #expect(first == cached)
        #expect(first.red > first.blue)
        #expect(second.blue > second.red)
    }

    @Test("Transparent artwork falls back to dark gray")
    func transparentArtwork() async throws {
        let context = try makeContext()
        let image = try #require(context.makeImage())
        let color = await LyricsArtworkColorCache().color(for: "transparent", image: image)
        #expect(color == .fallback)
    }

    private func makeContext() throws -> CGContext {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
