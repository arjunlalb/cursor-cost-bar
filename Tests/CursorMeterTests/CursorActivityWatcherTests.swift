import XCTest
@testable import CursorMeter

@MainActor
final class CursorActivityWatcherTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    private func waitUntil(_ timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    func testWriteEventFiresOnActivity() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wal")
        try Data("x".utf8).write(to: file)

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: file.path) { fired += 1 }
        watcher.start()
        XCTAssertTrue(watcher.isWatching)

        try append("y", to: file)
        await waitUntil { fired >= 1 }
        XCTAssertGreaterThanOrEqual(fired, 1)
        watcher.stop()
    }

    func testStopDeliversNoFurtherEvents() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wal")
        try Data("x".utf8).write(to: file)

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: file.path) { fired += 1 }
        watcher.start()
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)

        try append("y", to: file)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fired, 0)
    }

    func testMissingParentDirectoryIsInertNoOp() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
            .appendingPathComponent("wal")

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: missing.path) { fired += 1 }
        watcher.start()   // must not crash
        XCTAssertFalse(watcher.isWatching)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fired, 0)
        watcher.stop()    // idempotent, must not crash
    }
}
