//
//  AvatarURLBuilder.swift
//  Yattee
//
//  Utility for constructing channel avatar URLs from Invidious metadata.
//

import Foundation
import Nuke

/// Utility for constructing channel avatar URLs from Invidious metadata
enum AvatarURLBuilder {

    /// Available avatar sizes on Yattee Server

    /// Constructs the effective avatar URL for a channel
    /// - Parameters:
    ///   - channelID: The channel ID
    ///   - directURL: Direct avatar URL if available (from API response)
    ///   - serverURL: Yattee Server base URL
    ///   - size: Desired size in points (will be doubled for retina and rounded to nearest available)
    /// - Returns: URL to use for avatar, or nil if unavailable
    static func avatarURL(
        channelID: String,
        directURL: URL?,
        serverURL: URL?,
        size: Int
    ) -> URL? {
        directURL
    }

    /// Builds the Yattee Server avatar URL for a channel

    /// Creates an ImageRequest with auth header for Yattee Server avatar URLs
    /// - Parameters:
    ///   - url: The avatar URL
    ///   - authHeader: Optional Basic Auth header for Yattee Server
    /// - Returns: ImageRequest configured with auth if needed, or nil if URL is nil
    static func imageRequest(url: URL?, authHeader: String?) -> ImageRequest? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        // Only add auth header for Yattee Server avatar URLs
        if let authHeader, url.path.contains("/api/v1/channels/") && url.path.contains("/avatar/") {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return ImageRequest(urlRequest: request)
    }
}
