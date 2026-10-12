import XCTest
@testable import KonomiTV

final class PlaybackSessionTests: XCTestCase {
    private let server = try! ServerAddress(input: "https://tv.example:7000/")

    func testAcceptsOnlyRecordingKeepAlive() {
        let url = URL(string: "https://tv.example:7000/api/streams/video/42/1080p-hevc/keep-alive?session_id=abc_123")!
        XCTAssertEqual(PlaybackSession(observedURL: url, server: server)?.url, url)
    }

    func testRejectsUntrustedOrUnexpectedRequests() {
        let rejected = [
            "http://tv.example:7000/api/streams/video/42/1080p/keep-alive?session_id=abc",
            "https://other.example:7000/api/streams/video/42/1080p/keep-alive?session_id=abc",
            "https://tv.example/api/streams/video/42/1080p/keep-alive?session_id=abc",
            "https://user:password@tv.example:7000/api/streams/video/42/1080p/keep-alive?session_id=abc",
            "https://tv.example:7000/api/users/me?session_id=abc",
            "https://tv.example:7000/api/streams/video/42/1080p/playlist?session_id=abc",
            "https://tv.example:7000/api/streams/video/42/1080p/keep-alive?session_id=abc&next=https://other.example",
            "https://tv.example:7000/api/streams/video/42/1080p/keep-alive?session_id=abc&session_id=def",
            "https://tv.example:7000/api/streams/video/42/1080p/keep-alive?session_id=abc#fragment",
            "https://tv.example:7000/api/streams/video/42/1080p/keep-alive?session_id=%2Fescape",
            "https://tv.example:7000/api/streams/video/42/1080p%2F..%2Fadmin/keep-alive?session_id=abc"
        ]
        for raw in rejected {
            XCTAssertNil(PlaybackSession(observedURL: URL(string: raw)!, server: server), raw)
        }
    }
}
