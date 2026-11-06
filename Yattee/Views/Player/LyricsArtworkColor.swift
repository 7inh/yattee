//
//  LyricsArtworkColor.swift
//  Yattee
//
//  Samples loaded artwork and caches dark, readable lyrics backgrounds.
//

import Foundation
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct LyricsArtworkColor: Codable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = LyricsArtworkColor(red: 0.12, green: 0.12, blue: 0.14)

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// WCAG relative luminance, calculated in linear sRGB.
    var luminance: Double {
        Self.luminance(red: red, green: green, blue: blue)
    }

    static func darkened(red: Double, green: Double, blue: Double) -> Self {
        let red = min(1, max(0, red))
        let green = min(1, max(0, green))
        let blue = min(1, max(0, blue))
        // Preserve the hue while darkening by at least 35%. Leave a small
        // margin below the luminance limit for 4.5:1 contrast against white.
        let maximumLuminance = 1.05 / 4.5 - 0.05 - 0.001
        var lower = 0.0
        var upper = 0.65
        for _ in 0..<20 {
            let scale = (lower + upper) / 2
            if luminance(red: red * scale, green: green * scale, blue: blue * scale) <= maximumLuminance {
                lower = scale
            } else {
                upper = scale
            }
        }
        return Self(red: red * lower, green: green * lower, blue: blue * lower)
    }

    private static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// MARK: - Artwork Sampling

actor LyricsArtworkColorCache {
    static let shared = LyricsArtworkColorCache()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var colors: [String: LyricsArtworkColor] = [:]
    private var videoIDs: [String] = []

    func color(for videoID: String, image: CGImage) -> LyricsArtworkColor {
        if let cached = colors[videoID] { return cached }

        let source = CIImage(cgImage: image)
        let scale = min(1, 32 / max(source.extent.width, source.extent.height))
        let thumbnail = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filter = CIFilter.areaAverage()
        filter.inputImage = thumbnail
        filter.extent = thumbnail.extent
        guard let output = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return .fallback }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
        guard pixel.allSatisfy(\.isFinite), pixel[3] > 0 else { return .fallback }
        let color = LyricsArtworkColor.darkened(red: Double(pixel[0]), green: Double(pixel[1]), blue: Double(pixel[2]))
        colors[videoID] = color
        videoIDs.append(videoID)
        // Keep repeated toggles and recently played videos instant without
        // retaining an unbounded cache over a long playback session.
        if videoIDs.count > 64 {
            colors.removeValue(forKey: videoIDs.removeFirst())
        }
        return color
    }
}
