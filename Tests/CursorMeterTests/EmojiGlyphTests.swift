import XCTest
@testable import CursorMeter

final class EmojiGlyphTests: XCTestCase {
    func testSizeMatchesRequest() {
        let img = CircularProgressIcon.makeEmojiImage(emoji: "⚡", size: NSSize(width: 22, height: 22))
        XCTAssertEqual(img.size.width, 22, accuracy: 0.5)
        XCTAssertEqual(img.size.height, 22, accuracy: 0.5)
    }

    func testNonEmptyRendering() {
        let img = CircularProgressIcon.makeEmojiImage(emoji: "🚀", size: NSSize(width: 22, height: 22))
        // sanity: representations exist
        XCTAssertFalse(img.representations.isEmpty)
    }

    func testGlowDoesNotChangeSize() {
        let plain = CircularProgressIcon.makeEmojiImage(emoji: "🚀", size: NSSize(width: 22, height: 22), glow: false)
        let glow = CircularProgressIcon.makeEmojiImage(emoji: "🚀", size: NSSize(width: 22, height: 22), glow: true)
        XCTAssertEqual(plain.size, glow.size)
    }
}
