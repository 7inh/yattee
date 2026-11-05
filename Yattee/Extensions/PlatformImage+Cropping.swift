//
//  PlatformImage+Cropping.swift
//  Yattee
//
//  Cross-platform image cropping for extracting thumbnails from sprite sheets.
//

import Foundation
import CoreGraphics

import UIKit

extension UIImage {
    /// Crops the image to the specified rect.
    /// - Parameter rect: The rect to crop in image coordinates (origin at top-left)
    /// - Returns: The cropped image, or nil if cropping fails
    func cropped(to rect: CGRect) -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }

        // Scale rect for image scale (Retina displays)
        let scale = self.scale
        let scaledRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        guard let croppedCGImage = cgImage.cropping(to: scaledRect) else {
            return nil
        }

        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: .up)
    }
}
