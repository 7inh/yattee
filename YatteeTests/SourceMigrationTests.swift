//
//  SourceMigrationTests.swift
//  Yattee
//
//  Upgrades mixed saved-source arrays without dropping valid Invidious entries.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Invidious source migration")
struct SourceMigrationTests {
    @Test("Unsupported and corrupt source records are ignored individually")
    func mixedSources() throws {
        let instance = Instance(type: .invidious, url: URL(string: "https://example.com")!)
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(instance)) as! [String: Any]
        let oldRecords = ["piped", "peertube", "yatteeServer", "webdav", "smb", "localFolder"].map { type in
            var record = valid
            record["type"] = type
            return record
        }
        let data = try JSONSerialization.data(withJSONObject: [valid] + oldRecords + [["type": "invidious"]] + [valid])
        let decoded = try JSONDecoder().decode(LossyDecodableArray<Instance>.self, from: data)
        #expect(decoded.elements == [instance, instance])
    }

    @Test("Only HTTP and HTTPS instance URLs are accepted")
    func sourceURLs() {
        #expect(Instance.validateURL("invidious.example.com")?.absoluteString == "https://invidious.example.com")
        #expect(Instance.validateURL("smb://server/share") == nil)
        #expect(Instance.validateURL("file:///tmp/music") == nil)
    }
}
