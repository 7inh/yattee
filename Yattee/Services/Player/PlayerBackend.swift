//
//  PlayerBackend.swift
//  Yattee
//
//  Abstract interface for audio playback backends.
//

import Foundation
import AVFoundation
import SwiftUI

// MARK: - Stream Format

/// Stream format categories for backend compatibility.
enum StreamFormat: String, CaseIterable, Sendable {
    case hls           // HTTP Live Streaming
    case dash          // DASH/MPD
    case mp4H264       // MP4 with H.264
    case mp4H265       // MP4 with H.265/HEVC
    case webmVP9       // WebM with VP9
    case webmAV1       // WebM with AV1
    case audioAAC      // AAC audio
    case audioOpus     // Opus audio
    case audioMP3      // MP3 audio

    /// Detect format from stream properties.
    static func detect(from stream: Stream) -> StreamFormat {
        let format = stream.format.lowercased()
        let videoCodec = stream.videoCodec?.lowercased() ?? ""
        let audioCodec = stream.audioCodec?.lowercased() ?? ""
        let mimeType = stream.mimeType?.lowercased() ?? ""

        // Check for HLS
        if mimeType.contains("mpegurl") || format == "hls" {
            return .hls
        }

        // Check for DASH
        if mimeType.contains("dash") || format == "dash" {
            return .dash
        }

        // Audio-only streams
        if stream.isAudioOnly {
            if audioCodec.contains("opus") {
                return .audioOpus
            } else if audioCodec.contains("mp3") || mimeType.contains("mp3") {
                return .audioMP3
            } else {
                return .audioAAC
            }
        }

        // Video streams
        if format == "webm" || mimeType.contains("webm") {
            if videoCodec.contains("av1") || videoCodec.contains("av01") {
                return .webmAV1
            } else {
                return .webmVP9
            }
        }

        if format == "mp4" || mimeType.contains("mp4") {
            if videoCodec.contains("hev") || videoCodec.contains("hvc") || videoCodec.contains("265") {
                return .mp4H265
            } else {
                return .mp4H264
            }
        }

        // Default to MP4 H.264
        return .mp4H264
    }
}

// MARK: - Backend Type

/// Available player backend types.
enum PlayerBackendType: String, CaseIterable, Codable, Sendable {
    case avFoundation

    var displayName: String { "AVFoundation" }
    var supportedFormats: Set<StreamFormat> { [.audioAAC, .audioMP3, .hls] }
    var supportsAirPlay: Bool { true }
    var supportsPiP: Bool { false }
}

// MARK: - Backend Delegate

/// Delegate protocol for backend callbacks.
@MainActor
protocol PlayerBackendDelegate: AnyObject {
    func backend(_ backend: any PlayerBackend, didUpdateTime time: TimeInterval)
    func backend(_ backend: any PlayerBackend, didUpdateDuration duration: TimeInterval)
    func backend(_ backend: any PlayerBackend, didChangeState state: PlaybackState)
    func backend(_ backend: any PlayerBackend, didUpdateBufferedTime time: TimeInterval)
    func backend(_ backend: any PlayerBackend, didUpdateBufferProgress progress: Int)
    func backend(_ backend: any PlayerBackend, didUpdateVideoSize width: Int, height: Int)
    func backend(_ backend: any PlayerBackend, didUpdateRetryState currentRetry: Int, maxRetries: Int, isRetrying: Bool, exhausted: Bool)
    func backend(_ backend: any PlayerBackend, didRequestStreamRefresh atTime: TimeInterval?)
    func backendDidBecomeReady(_ backend: any PlayerBackend)
    func backendDidFinishPlaying(_ backend: any PlayerBackend)
}

// MARK: - Player Backend Protocol

/// Abstract interface for audio playback backends.
/// Implemented by AVAudioBackend.
@MainActor
protocol PlayerBackend: AnyObject {
    /// The type of this backend.
    var backendType: PlayerBackendType { get }

    /// Delegate for callbacks.
    var delegate: PlayerBackendDelegate? { get set }

    /// Current playback rate (1.0 = normal).
    var rate: Float { get set }

    /// Current volume (0.0 - 1.0).
    var volume: Float { get set }

    /// Whether audio is muted.
    var isMuted: Bool { get set }

    // MARK: - Playback Control

    /// Load a stream for playback.
    /// - Parameters:
    ///   - stream: The standalone audio stream to play
    ///   - audioStream: A separate audio rendition, preferred over stream
    ///   - autoplay: Whether to start playback automatically
    func load(stream: Stream, audioStream: Stream?, autoplay: Bool) async throws

    /// Start or resume playback.
    func play()

    /// Pause playback.
    func pause()

    /// Stop playback and release resources.
    func stop()

    /// Seek to a specific time.
    /// - Parameters:
    ///   - time: The time to seek to in seconds
    ///   - showLoading: If true, show loading state during seek (e.g., for SponsorBlock intro skips)
    func seek(to time: TimeInterval, showLoading: Bool) async

    /// Signal that an initial seek will be performed after load completes.
    /// Defer ready callbacks until the resume position is reached.
    func prepareForInitialSeek()

    // MARK: - Background Playback

    /// Handle scene phase changes for background playback.
    /// PlayerService decides whether audio continues in the background.
    /// - Parameters:
    ///   - phase: The new scene phase
    ///   - isPiPActive: Whether Picture-in-Picture is currently active
    func handleScenePhase(_ phase: ScenePhase, isPiPActive: Bool)
}

// MARK: - Default Implementations

extension PlayerBackend {
    /// Default implementation does nothing.
    func handleScenePhase(_ phase: ScenePhase, isPiPActive: Bool) {
        // No-op by default
    }
}

// MARK: - Backend Errors

/// Errors that can occur during backend operations.
enum BackendError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat(StreamFormat)
    case loadFailed(String)
    case seekFailed
    case notReady
    case switchFailed(String)
    case backendUnavailable(PlayerBackendType)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported stream format: \(format.rawValue)"
        case .loadFailed(let reason):
            return "Failed to load stream: \(reason)"
        case .seekFailed:
            return "Failed to seek to position"
        case .notReady:
            return "Backend is not ready for playback"
        case .switchFailed(let reason):
            return "Failed to switch backends: \(reason)"
        case .backendUnavailable(let type):
            return "\(type.displayName) backend is not available"
        }
    }
}
