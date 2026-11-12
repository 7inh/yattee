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

    @Test("The default goes first and replaces the retired Tailscale instance as active")
    func replacesRetiredActive() throws {
        let defaults = makeDefaults()
        let retired = Instance(type: .invidious, url: URL(string: "http://100.94.63.101:3000")!)
        defaults.set(try JSONEncoder().encode([retired]), forKey: "configuredInstances")
        defaults.set(retired.id.uuidString, forKey: "activeInstanceID")

        let manager = InstancesManager(defaults: defaults, seedsDefaultInstance: true)

        #expect(manager.instances.map(\.url) == [InstancesManager.defaultInstanceURL, retired.url])
        #expect(manager.activeInstance?.url == InstancesManager.defaultInstanceURL)
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
