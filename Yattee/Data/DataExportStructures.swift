//
//  DataExportStructures.swift
//  Yattee
//
//  Codable structures for exporting data to iCloud sync.
//

import Foundation

// MARK: - Subscription Export

/// Codable struct for exporting Subscription to iCloud.
struct SubscriptionExport: Codable {
    let channelID: String
    let sourceRawValue: String
    let instanceURLString: String?
    let name: String
    let channelDescription: String?
    let subscriberCount: Int?
    let avatarURLString: String?
    let bannerURLString: String?
    let isVerified: Bool
    let subscribedAt: Date
    let lastUpdatedAt: Date

    init(from subscription: Subscription) {
        self.channelID = subscription.channelID
        self.sourceRawValue = subscription.sourceRawValue
        self.instanceURLString = subscription.instanceURLString
        self.name = subscription.name
        self.channelDescription = subscription.channelDescription
        self.subscriberCount = subscription.subscriberCount
        self.avatarURLString = subscription.avatarURLString
        self.bannerURLString = subscription.bannerURLString
        self.isVerified = subscription.isVerified
        self.subscribedAt = subscription.subscribedAt
        self.lastUpdatedAt = subscription.lastUpdatedAt
    }
}

// MARK: - Media Source Export

/// Codable struct for exporting MediaSource (WebDAV and SMB) to iCloud.
/// Note: Local folder sources are never synced as they are device-specific.
