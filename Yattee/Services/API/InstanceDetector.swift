//
//  InstanceDetector.swift
//  Yattee
//
//  Automatically detects backend instance type by probing API endpoints.
//

import Foundation

/// Errors that can occur during instance detection.
enum DetectionError: Error, Sendable {
    case sslCertificateError
    case networkError(String)
    case unknownType
    case invalidURL
    case timeout
    /// The instance is fronted by an HTTP Basic Auth challenge (401). The user must
    /// supply credentials before detection can identify the backend type.
    case basicAuthRequired
    /// Detection was retried with HTTP Basic Auth credentials but the server still
    /// returned 401 — the credentials are invalid.
    case basicAuthInvalid
    /// The URL points to the Piped web frontend SPA, not its API backend. The
    /// frontend serves the same `index.html` for every path, so JSON probes can
    /// never succeed — the user must supply the API URL instead.

    var localizedDescription: String {
        switch self {
        case .sslCertificateError:
            return String(localized: "sources.error.sslCertificate")
        case .networkError(let message):
            return message
        case .unknownType:
            return String(localized: "sources.error.couldNotDetect")
        case .invalidURL:
            return String(localized: "sources.validation.invalidURL")
        case .timeout:
            return String(localized: "sources.error.timeout")
        case .basicAuthRequired:
            return String(localized: "sources.error.basicAuthRequired")
        case .basicAuthInvalid:
            return String(localized: "sources.error.basicAuthInvalid")
        }
    }
}

/// Result of instance detection including type and authentication requirements.
struct InstanceDetectionResult: Sendable {
    let type: InstanceType

    init(type: InstanceType, requiresAuth: Bool = false) {
        self.type = type
    }
}

/// Only Invidious instances are supported.
actor InstanceDetector {
    private let httpClient: HTTPClient
    init(httpClient: HTTPClient) { self.httpClient = httpClient }

    func detectWithResult(url: URL, basicAuthHeader: String? = nil) async -> Result<InstanceDetectionResult, DetectionError> {
        do {
            let headers = basicAuthHeader.map { ["Authorization": $0] }
            let data = try await httpClient.performRaw(URLRequest(url: url.appendingPathComponent("api/v1/stats")), customHeaders: headers)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["software"] != nil else { return .failure(.unknownType) }
            return .success(InstanceDetectionResult(type: .invidious))
        } catch { return .failure(.networkError(error.localizedDescription)) }
    }
}
