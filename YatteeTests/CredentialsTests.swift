//
//  CredentialsTests.swift
//  YatteeTests
//
//  Tests for credential managers (Invidious and Piped).
//

import Testing
import Foundation
@testable import Yattee

// MARK: - PipedCredentialsManager Tests

// MARK: - InvidiousCredentialsManager Tests

@Suite("InvidiousCredentialsManager Tests")
@MainActor
struct InvidiousCredentialsManagerTests {

    private func createTestInstance() -> Instance {
        Instance(type: .invidious, url: URL(string: "https://invidious.test.example")!)
    }

    @Test("setSID stores session and updates loggedInInstanceIDs")
    func setSIDStoresSession() {
        let manager = InvidiousCredentialsManager()
        let instance = createTestInstance()
        let sid = "test-session-id-\(UUID().uuidString)"

        manager.setSID(sid, for: instance)

        #expect(manager.loggedInInstanceIDs.contains(instance.id))

        // Cleanup
        manager.deleteSID(for: instance)
    }

    @Test("sid retrieves stored session")
    func sidRetrievesSession() {
        let manager = InvidiousCredentialsManager()
        let instance = createTestInstance()
        let sid = "test-session-id-\(UUID().uuidString)"

        manager.setSID(sid, for: instance)
        let retrieved = manager.sid(for: instance)

        #expect(retrieved == sid)

        // Cleanup
        manager.deleteSID(for: instance)
    }

    @Test("sid returns nil for unknown instance")
    func sidReturnsNilForUnknown() {
        let manager = InvidiousCredentialsManager()
        let instance = createTestInstance()

        let retrieved = manager.sid(for: instance)

        #expect(retrieved == nil)
    }

    @Test("deleteSID removes session and updates loggedInInstanceIDs")
    func deleteSIDRemovesSession() {
        let manager = InvidiousCredentialsManager()
        let instance = createTestInstance()
        let sid = "test-session-id-\(UUID().uuidString)"

        manager.setSID(sid, for: instance)
        #expect(manager.loggedInInstanceIDs.contains(instance.id))

        manager.deleteSID(for: instance)

        #expect(!manager.loggedInInstanceIDs.contains(instance.id))
        #expect(manager.sid(for: instance) == nil)
    }

    @Test("Protocol methods delegate correctly")
    func protocolMethodsDelegate() {
        let manager = InvidiousCredentialsManager()
        let instance = createTestInstance()
        let sid = "test-session-id-\(UUID().uuidString)"

        // Test setCredential -> setSID
        manager.setCredential(sid, for: instance)
        #expect(manager.sid(for: instance) == sid)

        // Test credential -> sid
        #expect(manager.credential(for: instance) == sid)

        // Test deleteCredential -> deleteSID
        manager.deleteCredential(for: instance)
        #expect(manager.sid(for: instance) == nil)
    }

    @Test("isLoggedIn returns correct state")
    func isLoggedInReturnsCorrectState() {
        let manager = InvidiousCredentialsManager()
        let instance = createTestInstance()
        let sid = "test-session-id-\(UUID().uuidString)"

        #expect(manager.isLoggedIn(for: instance) == false)

        manager.setSID(sid, for: instance)
        #expect(manager.isLoggedIn(for: instance) == true)

        manager.deleteSID(for: instance)
        #expect(manager.isLoggedIn(for: instance) == false)
    }

    @Test("Thumbnail cache stores and retrieves URLs")
    func thumbnailCacheWorks() {
        let manager = InvidiousCredentialsManager()
        let channelID = "UC\(UUID().uuidString.prefix(22))"
        let thumbnailURL = URL(string: "https://example.com/thumb.jpg")!

        manager.setThumbnailURL(thumbnailURL, forChannelID: channelID)
        let retrieved = manager.thumbnailURL(forChannelID: channelID)

        #expect(retrieved == thumbnailURL)

        // Cleanup
        manager.clearThumbnailCache()
    }

    @Test("uncachedChannelIDs filters correctly")
    func uncachedChannelIDsFilters() {
        let manager = InvidiousCredentialsManager()
        let cachedID = "UCcached\(UUID().uuidString.prefix(16))"
        let uncachedID = "UCuncached\(UUID().uuidString.prefix(14))"

        manager.setThumbnailURL(URL(string: "https://example.com/thumb.jpg")!, forChannelID: cachedID)

        let uncached = manager.uncachedChannelIDs(from: [cachedID, uncachedID])

        #expect(uncached.count == 1)
        #expect(uncached.contains(uncachedID))
        #expect(!uncached.contains(cachedID))

        // Cleanup
        manager.clearThumbnailCache()
    }

    @Test("setThumbnailURLs batches correctly")
    func setThumbnailURLsBatches() {
        let manager = InvidiousCredentialsManager()
        let id1 = "UC1\(UUID().uuidString.prefix(19))"
        let id2 = "UC2\(UUID().uuidString.prefix(19))"
        let url1 = URL(string: "https://example.com/thumb1.jpg")!
        let url2 = URL(string: "https://example.com/thumb2.jpg")!

        manager.setThumbnailURLs([id1: url1, id2: url2])

        #expect(manager.thumbnailURL(forChannelID: id1) == url1)
        #expect(manager.thumbnailURL(forChannelID: id2) == url2)

        // Cleanup
        manager.clearThumbnailCache()
    }
}

// MARK: - InstanceCredentialsManager Protocol Tests

@Suite("InstanceCredentialsManager Protocol Tests")
@MainActor
struct InstanceCredentialsManagerProtocolTests {

    @Test("InvidiousCredentialsManager conforms to protocol")
    func invidiousConformsToProtocol() {
        let manager: InstanceCredentialsManager = InvidiousCredentialsManager()
        let instance = Instance(type: .invidious, url: URL(string: "https://invidious.test.example")!)
        let sid = "protocol-test-\(UUID().uuidString)"

        manager.setCredential(sid, for: instance)
        #expect(manager.credential(for: instance) == sid)
        #expect(manager.isLoggedIn(for: instance) == true)

        manager.deleteCredential(for: instance)
        #expect(manager.isLoggedIn(for: instance) == false)
    }
}
