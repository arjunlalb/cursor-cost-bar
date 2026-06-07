import XCTest
@testable import CursorMeter

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private let checker = UpdateChecker.shared

    func testNewerMajor() {
        XCTAssertTrue(checker.isNewer(remote: "1.0.0", current: "0.1.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(checker.isNewer(remote: "0.2.0", current: "0.1.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(checker.isNewer(remote: "0.1.1", current: "0.1.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(checker.isNewer(remote: "0.1.0", current: "0.1.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(checker.isNewer(remote: "0.1.0", current: "0.2.0"))
    }

    func testMismatchedLength() {
        XCTAssertTrue(checker.isNewer(remote: "1.0", current: "0.9.9"))
        XCTAssertFalse(checker.isNewer(remote: "0.9", current: "0.9.1"))
    }

    // MARK: - classify(...) — UpdateCheckResult mapping (#58)

    private func makeResponse(status: Int) -> URLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testClassify_validReleaseNewer_returnsAvailable() {
        let json = """
        {"tag_name": "v0.5.0", "html_url": "https://github.com/x/y/releases/tag/v0.5.0"}
        """
        let result = UpdateChecker.classify(
            data: Data(json.utf8),
            response: makeResponse(status: 200),
            currentVersion: "0.4.0"
        )
        if case .available(let release) = result {
            XCTAssertEqual(release.tagName, "v0.5.0")
            XCTAssertEqual(release.version, "0.5.0")
            XCTAssertEqual(release.htmlURL, "https://github.com/x/y/releases/tag/v0.5.0")
        } else {
            XCTFail("expected .available, got \(result)")
        }
    }

    func testClassify_sameVersion_returnsUpToDate() {
        let json = """
        {"tag_name": "v0.4.0", "html_url": "https://example.com/r"}
        """
        let result = UpdateChecker.classify(
            data: Data(json.utf8),
            response: makeResponse(status: 200),
            currentVersion: "0.4.0"
        )
        XCTAssertEqual(result, .upToDate)
    }

    func testClassify_olderRemote_returnsUpToDate() {
        let json = """
        {"tag_name": "v0.3.0", "html_url": "https://example.com/r"}
        """
        let result = UpdateChecker.classify(
            data: Data(json.utf8),
            response: makeResponse(status: 200),
            currentVersion: "0.4.0"
        )
        XCTAssertEqual(result, .upToDate)
    }

    func testClassify_non200_returnsFailed() {
        let result = UpdateChecker.classify(
            data: Data(),
            response: makeResponse(status: 503),
            currentVersion: "0.4.0"
        )
        if case .failed(let reason) = result {
            XCTAssertTrue(reason.contains("503"))
        } else {
            XCTFail("expected .failed, got \(result)")
        }
    }

    func testClassify_malformedJSON_returnsFailed() {
        let result = UpdateChecker.classify(
            data: Data("not-json".utf8),
            response: makeResponse(status: 200),
            currentVersion: "0.4.0"
        )
        if case .failed(let reason) = result {
            XCTAssertEqual(reason, "Couldn't read release info")
        } else {
            XCTFail("expected .failed, got \(result)")
        }
    }

    func testClassify_missingTagName_returnsFailed() {
        let json = """
        {"html_url": "https://example.com/r"}
        """
        let result = UpdateChecker.classify(
            data: Data(json.utf8),
            response: makeResponse(status: 200),
            currentVersion: "0.4.0"
        )
        if case .failed(let reason) = result {
            XCTAssertEqual(reason, "Couldn't read release info")
        } else {
            XCTFail("expected .failed, got \(result)")
        }
    }

    func testClassify_nonHTTPResponse_returnsFailed() {
        let result = UpdateChecker.classify(
            data: Data(),
            response: URLResponse(
                url: URL(string: "https://example.com")!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            ),
            currentVersion: "0.4.0"
        )
        if case .failed(let reason) = result {
            XCTAssertEqual(reason, "Invalid response from GitHub")
        } else {
            XCTFail("expected .failed, got \(result)")
        }
    }
}
