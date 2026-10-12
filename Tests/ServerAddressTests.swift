import XCTest
@testable import KonomiTV

final class ServerAddressTests: XCTestCase {
    func testCanonicalAddressAndDefaultPort() throws {
        let address = try ServerAddress(input: " \nHTTPS://TV.Example.COM:443\n ")
        XCTAssertEqual(address.url.absoluteString, "https://tv.example.com/")
        XCTAssertEqual(address.origin, "https://tv.example.com")
        XCTAssertEqual(address, try ServerAddress(input: "https://tv.example.com/"))
    }

    func testKonomiTVEndpointAndReverseProxyMountArePreserved() throws {
        let direct = try ServerAddress(input: "https://192-168-1-10.local.konomi.tv:7000/")
        XCTAssertEqual(direct.origin, "https://192-168-1-10.local.konomi.tv:7000")
        let proxy = try ServerAddress(input: "https://tv.example.com/services/konomi")
        XCTAssertEqual(proxy.url.absoluteString, "https://tv.example.com/services/konomi/")
        XCTAssertTrue(proxy.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/services/konomi"))))
        XCTAssertTrue(proxy.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/services/konomi/tv/watch/gr011?quality=1080p#player"))))
        XCTAssertFalse(proxy.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/services/konomi-other/"))))
        XCTAssertFalse(proxy.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/services/"))))
        XCTAssertFalse(proxy.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/"))))
    }

    func testOriginIncludesEffectiveHTTPSPort() throws {
        let address = try ServerAddress(input: "https://tv.example.com:7000/")
        XCTAssertTrue(address.sameOrigin(try XCTUnwrap(URL(string: "https://tv.example.com:7000/watch/"))))
        for candidate in [
            "https://tv.example.com/", "https://tv.example.com:7001/",
            "http://tv.example.com:7000/", "https://tv.example.com.evil.test:7000/",
            "https://other.example.com:7000/", "https://user@tv.example.com:7000/"
        ] {
            XCTAssertFalse(address.sameOrigin(try XCTUnwrap(URL(string: candidate))), candidate)
        }
        let standard = try ServerAddress(input: "https://tv.example.com/")
        XCTAssertTrue(standard.sameOrigin(try XCTUnwrap(URL(string: "https://TV.EXAMPLE.COM:443/"))))
    }

    func testRejectsUnsafeOrAmbiguousServerAddresses() {
        for value in [
            "", "tv.example.com", "http://tv.example.com/", "file:///tmp/index.html", "javascript:alert(1)",
            "https://user:secret@tv.example.com/", "https://@tv.example.com/",
            "https://tv.example.com/?token=secret", "https://tv.example.com/#player",
            "https://tv.example.com/?", "https://tv.example.com/#",
            "https://tv.example.com:0/", "https://tv.example.com:65536/", "https://tv.example.com:notaport/", "https://tv.example.com:/",
            "https://tv.example.com/a b/", "https://tv.example.com/invalid%/", "https://%74v.example.com/",
            "https://tv.example.com/../", "https://tv.example.com/%2e%2e/", "https://tv.example.com/%2Fadmin/",
            "https://tv.example.com/%252e%252e/", "https://tv.example.com/%255cadmin/",
            "https://tv.example.com\\@evil.test/", "https://-invalid.example/", "https://[abcd:1234]/"
        ] {
            XCTAssertThrowsError(try ServerAddress(input: value), value)
        }
    }

    func testPathEscapesCannotLeaveMountPoint() throws {
        let address = try ServerAddress(input: "https://tv.example.com/konomi/")
        for path in ["/konomi/../admin", "/konomi/%2e%2e/admin", "/konomi/%2fadmin", "/konomi/%5cadmin", "/konomi/%252e%252e/admin"] {
            let candidate = try XCTUnwrap(URL(string: "https://tv.example.com\(path)"))
            XCTAssertFalse(address.containsNavigation(candidate), path)
        }
    }

    func testIPv6AndEscapedBasePath() throws {
        let ipv6 = try ServerAddress(input: "https://[2001:db8::1]:7000/konomi")
        XCTAssertEqual(ipv6.origin, "https://[2001:db8::1]:7000")
        XCTAssertTrue(ipv6.containsNavigation(try XCTUnwrap(URL(string: "https://[2001:db8::1]:7000/konomi/tv/"))))
        let encodedPath = try ServerAddress(input: "https://tv.example.com/team%20tv/")
        XCTAssertTrue(encodedPath.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/team%20tv/watch/"))))
        XCTAssertFalse(encodedPath.containsNavigation(try XCTUnwrap(URL(string: "https://tv.example.com/team%20tv-other/"))))
    }

    func testCodableRevalidatesStoredAddresses() throws {
        let address = try ServerAddress(input: "https://tv.example.com/konomi/")
        let data = try JSONEncoder().encode(address)
        XCTAssertEqual(try JSONDecoder().decode(ServerAddress.self, from: data), address)
        let unsafe = try JSONEncoder().encode("http://tv.example.com/")
        XCTAssertThrowsError(try JSONDecoder().decode(ServerAddress.self, from: unsafe))
    }

    func testSettingsPersistAndRejectCorruptValues() throws {
        let suite = "ServerAddressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let address = try ServerAddress(input: "https://tv.example.com:7000/konomi/")
        settings.serverAddress = address
        XCTAssertEqual(AppSettings(defaults: defaults).serverAddress, address)
        defaults.set("javascript:alert(1)", forKey: AppSettings.serverAddressKey)
        XCTAssertNil(settings.serverAddress)
        settings.serverAddress = nil
        XCTAssertNil(defaults.object(forKey: AppSettings.serverAddressKey))
    }
}
