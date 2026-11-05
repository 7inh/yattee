//
//  ServiceTests.swift
//  YatteeTests
//
//  Tests for service layer components including WebDAV client and storage utilities.
//

import Testing
import Foundation
@testable import Yattee

// MARK: - Storage Diagnostics Tests

@Suite("StorageDiagnostics Tests")
@MainActor
struct StorageDiagnosticsTests {

    @Test("StorageUsageItem initialization")
    func storageUsageItemInit() {
        let item = StorageUsageItem(
            name: "Downloads",
            path: "/path/to/downloads",
            size: 1024 * 1024 * 500, // 500 MB
            fileCount: 42
        )

        #expect(item.name == "Downloads")
        #expect(item.path == "/path/to/downloads")
        #expect(item.size == 524288000)
        #expect(item.fileCount == 42)
        #expect(!item.id.uuidString.isEmpty)
    }

    @Test("StorageUsageItem is Identifiable")
    func storageUsageItemIdentifiable() {
        let item1 = StorageUsageItem(name: "A", path: "/a", size: 100, fileCount: 1)
        let item2 = StorageUsageItem(name: "A", path: "/a", size: 100, fileCount: 1)

        // Each item should have unique ID even with same content
        #expect(item1.id != item2.id)
    }

    @Test("StorageDiagnostics formatted values")
    func diagnosticsFormattedValues() {
        let diagnostics = StorageDiagnostics(
            items: [],
            totalSize: 1024 * 1024 * 1024, // 1 GB
            documentsSize: 500 * 1024 * 1024,
            cachesSize: 200 * 1024 * 1024,
            appSupportSize: 100 * 1024 * 1024,
            tempSize: 50 * 1024 * 1024,
            otherSize: 150 * 1024 * 1024
        )

        #expect(!diagnostics.formattedTotal.isEmpty)
        #expect(!diagnostics.formattedDocuments.isEmpty)
        #expect(!diagnostics.formattedCaches.isEmpty)
        #expect(!diagnostics.formattedAppSupport.isEmpty)
        #expect(!diagnostics.formattedTemp.isEmpty)
    }

    @Test("StorageDiagnostics with items")
    func diagnosticsWithItems() {
        let items = [
            StorageUsageItem(name: "Downloads", path: "/downloads", size: 300_000_000, fileCount: 10),
            StorageUsageItem(name: "Cache", path: "/cache", size: 100_000_000, fileCount: 50),
            StorageUsageItem(name: "Temp", path: "/temp", size: 50_000_000, fileCount: 5)
        ]

        let diagnostics = StorageDiagnostics(
            items: items,
            totalSize: 450_000_000,
            documentsSize: 300_000_000,
            cachesSize: 100_000_000,
            appSupportSize: 0,
            tempSize: 50_000_000,
            otherSize: 0
        )

        #expect(diagnostics.items.count == 3)
        #expect(diagnostics.totalSize == 450_000_000)
    }

    @Test("scanAppStorage returns valid diagnostics")
    func scanAppStorageReturnsValid() {
        let diagnostics = scanAppStorage()

        #expect(diagnostics.totalSize >= 0)
        #expect(diagnostics.documentsSize >= 0)
        #expect(diagnostics.cachesSize >= 0)
        #expect(!diagnostics.formattedTotal.isEmpty)
    }
}

// MARK: - LockedStorage Tests

@Suite("LockedStorage Tests")
struct LockedStorageTests {

    @Test("LockedStorage read returns value")
    func readReturnsValue() {
        let storage = LockedStorage(42)
        let value = storage.read { $0 }
        #expect(value == 42)
    }

    @Test("LockedStorage write modifies value")
    func writeModifiesValue() {
        let storage = LockedStorage(0)
        storage.write { $0 += 10 }
        let value = storage.read { $0 }
        #expect(value == 10)
    }

    @Test("LockedStorage with string")
    func withString() {
        let storage = LockedStorage("hello")
        storage.write { $0 += " world" }
        let value = storage.read { $0 }
        #expect(value == "hello world")
    }

    @Test("LockedStorage with array")
    func withArray() {
        let storage = LockedStorage<[Int]>([])
        storage.write { $0.append(1) }
        storage.write { $0.append(2) }
        storage.write { $0.append(3) }
        let value = storage.read { $0 }
        #expect(value == [1, 2, 3])
    }

    @Test("LockedStorage read with transformation")
    func readWithTransformation() {
        let storage = LockedStorage([1, 2, 3, 4, 5])
        let sum = storage.read { $0.reduce(0, +) }
        #expect(sum == 15)
    }

    @Test("LockedStorage concurrent access")
    func concurrentAccess() async {
        let storage = LockedStorage(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    storage.write { $0 += 1 }
                }
            }
        }

        let finalValue = storage.read { $0 }
        #expect(finalValue == 100)
    }
}

// MARK: - MediaSourceError Tests

// MARK: - MediaSource Configuration Tests

// MARK: - MediaFile Tests
