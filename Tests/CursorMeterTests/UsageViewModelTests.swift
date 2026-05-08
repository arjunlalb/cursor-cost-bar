import XCTest
@testable import CursorMeter

final class UsageViewModelTests: XCTestCase {
    // MARK: - fallbackErrorMessage(for:)

    func testFallbackMessageForURLErrorTimedOut() {
        let error = URLError(.timedOut)
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Request timed out")
    }

    func testFallbackMessageForOtherURLError() {
        let error = URLError(.cannotFindHost)
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Network error")
    }

    func testFallbackMessageForDecodingError() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Failed to read usage data")
    }

    func testFallbackMessageForAPIHttpError() {
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: APIError.httpError(statusCode: 500)), "Server error (500)")
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: APIError.httpError(statusCode: 502)), "Server error (502)")
    }

    func testFallbackMessageForAPINetworkErrorWithTimeout() {
        let error = APIError.networkError(URLError(.timedOut))
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Request timed out")
    }

    func testFallbackMessageForAPINetworkErrorWithOtherURLError() {
        let error = APIError.networkError(URLError(.cannotConnectToHost))
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Network error")
    }

    func testFallbackMessageForUnknownError() {
        struct CustomError: Error {}
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: CustomError()), "Unexpected error")
    }

    /// Ensures the message never leaks raw error detail (URLs, debug strings).
    func testFallbackMessageDoesNotLeakRawDetail() {
        let url = URL(string: "https://www.cursor.com/api/usage-summary")!
        let urlError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let message = UsageViewModel.fallbackErrorMessage(for: urlError)
        XCTAssertFalse(message.contains("cursor.com"))
        XCTAssertFalse(message.contains("api/usage"))
    }
}
