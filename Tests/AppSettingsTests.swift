import XCTest
@testable import KonomiTV

final class AppSettingsTests: XCTestCase {
    func testLegacyEndpointMigratesOnlyOnce() throws {
        try withDefaults { defaults in
            defaults.set("HTTPS://TV.EXAMPLE.COM:443/konomi", forKey: AppSettings.serverAddressKey)
            let settings = AppSettings(defaults: defaults)
            let address = try ServerAddress(input: "https://tv.example.com/konomi/")
            XCTAssertEqual(settings.connectionHistory.map(\.address), [address])
            XCTAssertEqual(settings.connectionHistory.first?.lastConnectedAt, .distantPast)

            settings.deleteConnection(address)
            let reopened = AppSettings(defaults: defaults)
            XCTAssertTrue(reopened.connectionHistory.isEmpty)
            XCTAssertEqual(reopened.serverAddress, address)
        }
    }

    func testEnteringEndpointDoesNotRecordAnUnsuccessfulConnection() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let address = try ServerAddress(input: "https://tv.example.com/")
            settings.serverAddress = address
            XCTAssertTrue(settings.connectionHistory.isEmpty)
            XCTAssertTrue(AppSettings(defaults: defaults).connectionHistory.isEmpty)

            settings.recordConnection(address)
            XCTAssertEqual(settings.connectionHistory.map(\.address), [address])
        }
    }

    func testSuccessfulReconnectDeduplicatesAndPreservesPinAfterRestart() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let address = try ServerAddress(input: "https://tv.example.com/konomi/")
            let normalized = try ServerAddress(input: "HTTPS://TV.EXAMPLE.COM:443/konomi")
            settings.recordConnection(address, at: Date(timeIntervalSince1970: 1_000))
            settings.setConnectionPinned(address, isPinned: true)
            let recent = Date(timeIntervalSince1970: 2_000)
            settings.recordConnection(normalized, at: recent)

            let history = AppSettings(defaults: defaults).connectionHistory
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.first?.address, address)
            XCTAssertEqual(history.first?.lastConnectedAt, recent)
            XCTAssertEqual(history.first?.isPinned, true)
        }
    }

    func testPinsSortAboveRecentEndpointsAndUnpinRestoresRecency() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let older = try ServerAddress(input: "https://older.example.com/")
            let recent = try ServerAddress(input: "https://recent.example.com/")
            settings.recordConnection(older, at: Date(timeIntervalSince1970: 1_000))
            settings.recordConnection(recent, at: Date(timeIntervalSince1970: 2_000))
            XCTAssertEqual(settings.connectionHistory.map(\.address), [recent, older])
            settings.setConnectionPinned(older, isPinned: true)
            XCTAssertEqual(AppSettings(defaults: defaults).connectionHistory.map(\.address), [older, recent])
            settings.setConnectionPinned(older, isPinned: false)
            XCTAssertEqual(settings.connectionHistory.map(\.address), [recent, older])
        }
    }

    func testDeletingCurrentHistoryKeepsConnectionAndCanRecordAgain() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let current = try ServerAddress(input: "https://tv.example.com/")
            let other = try ServerAddress(input: "https://other.example.com/")
            settings.serverAddress = current
            settings.recordConnection(current, at: Date(timeIntervalSince1970: 1_000))
            settings.recordConnection(other, at: Date(timeIntervalSince1970: 2_000))
            settings.setConnectionPinned(current, isPinned: true)
            settings.deleteConnection(current)
            XCTAssertEqual(settings.serverAddress, current)
            XCTAssertEqual(settings.connectionHistory.map(\.address), [other])

            settings.recordConnection(current, at: Date(timeIntervalSince1970: 3_000))
            XCTAssertEqual(settings.connectionHistory.count, 2)
            XCTAssertEqual(settings.connectionHistory.first?.address, current)
            XCTAssertEqual(settings.connectionHistory.first?.isPinned, false)
        }
    }

    func testCorruptHistoryEntriesAreSkippedWithoutLosingValidRecords() throws {
        try withDefaults { defaults in
            let early = Date(timeIntervalSince1970: 1_000)
            let recent = Date(timeIntervalSince1970: 2_000)
            let records: [[String: Any]] = [
                ["address": "https://tv.example.com/", "lastConnectedAt": early, "isPinned": true],
                ["address": "HTTPS://TV.EXAMPLE.COM:443", "lastConnectedAt": recent, "isPinned": false],
                ["address": "javascript:alert(1)", "lastConnectedAt": recent, "isPinned": false],
                ["address": "https://invalid.example.com/", "lastConnectedAt": "yesterday", "isPinned": false],
                ["address": "https://missing-fields.example.com/"]
            ]
            defaults.set(records, forKey: AppSettings.connectionHistoryKey)
            let settings = AppSettings(defaults: defaults)
            let history = settings.connectionHistory
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.first?.address, try ServerAddress(input: "https://tv.example.com/"))
            XCTAssertEqual(history.first?.lastConnectedAt, recent)
            XCTAssertEqual(history.first?.isPinned, true)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
