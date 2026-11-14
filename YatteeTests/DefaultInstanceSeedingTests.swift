//
//  DefaultInstanceSeedingTests.swift
//  YatteeTests
//
//  Tests for seeding the shipped default Invidious instance.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Default Instance Seeding Tests")
@MainActor
struct DefaultInstanceSeedingTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "yattee.tests.seed.\(UUID().uuidString)")!
    }

    @Test("A fresh install gets the default instance as the active one")
    func freshInstall() {
        let manager = InstancesManager(defaults: makeDefaults(), seedsDefaultInstance: true)

        #expect(manager.instances.map(\.url) == [InstancesManager.defaultInstanceURL])
        #expect(manager.activeInstance?.url == InstancesManager.defaultInstanceURL)
    }

    @Test("Seeding happens once, so removing the default keeps it removed")
    func seedsOnce() {
        let defaults = makeDefaults()
        let first = InstancesManager(defaults: defaults, seedsDefaultInstance: true)
        first.remove(first.instances[0])

        let second = InstancesManager(defaults: defaults, seedsDefaultInstance: true)
        #expect(second.instances.isEmpty)
    }

    @Test("Retired shipped instances are removed and the default becomes active")
    func replacesRetiredActive() throws {
        let defaults = makeDefaults()
        let oldTailscale = Instance(type: .invidious, url: URL(string: "http://100.94.63.101:3000")!)
        let oldPublic = Instance(type: .invidious, url: URL(string: "https://yt.7inh.site")!)
        defaults.set(try JSONEncoder().encode([oldPublic, oldTailscale]), forKey: "configuredInstances")
        defaults.set(oldPublic.id.uuidString, forKey: "activeInstanceID")
        // A device that already seeded the previous default must still get the new one.
        defaults.set(true, forKey: "seededDefaultInstance.yt.7inh.site")

        let manager = InstancesManager(defaults: defaults, seedsDefaultInstance: true)

        #expect(manager.instances.map(\.url) == [InstancesManager.defaultInstanceURL])
        #expect(manager.activeInstance?.url == InstancesManager.defaultInstanceURL)
    }

    @Test("The default is plain HTTP on the home server's tailnet name")
    func defaultURL() {
        #expect(InstancesManager.defaultInstanceURL.absoluteString == "http://maydocui.taila1b96e.ts.net:3000")
    }

    @Test("An explicitly chosen other instance stays active")
    func keepsChosenActive() throws {
        let defaults = makeDefaults()
        let own = Instance(type: .invidious, url: URL(string: "https://inv.example.com")!)
        defaults.set(try JSONEncoder().encode([own]), forKey: "configuredInstances")
        defaults.set(own.id.uuidString, forKey: "activeInstanceID")

        let manager = InstancesManager(defaults: defaults, seedsDefaultInstance: true)

        #expect(manager.instances.count == 2)
        #expect(manager.activeInstance?.id == own.id)
    }

    @Test("Tests and other callers start empty unless they opt in")
    func optIn() {
        #expect(InstancesManager(defaults: makeDefaults()).instances.isEmpty)
    }
}
