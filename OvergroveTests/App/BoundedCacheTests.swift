import XCTest

@testable import Overgrove

final class BoundedCacheTests: XCTestCase {
    func testEvictsTheLeastRecentlyUsedEntryWhenFull() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")

        XCTAssertNil(cache.peek("a"), "the oldest entry is evicted")
        XCTAssertEqual(cache.peek("b"), 2)
        XCTAssertEqual(cache.peek("c"), 3)
        XCTAssertEqual(cache.count, 2)
    }

    func testReadingAnEntryKeepsItFromEviction() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c")

        XCTAssertEqual(cache.peek("a"), 1, "a was used after b")
        XCTAssertNil(cache.peek("b"))
    }

    func testPeekDoesNotCountAsUse() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.peek("a")
        cache.insert(3, for: "c")

        XCTAssertNil(cache.peek("a"))
    }

    func testReplacingAValueKeepsOneEntryAndMarksItRecent() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(10, for: "a")
        cache.insert(3, for: "c")

        XCTAssertEqual(cache.peek("a"), 10)
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.keys, ["a", "c"])
    }

    func testRemoval() {
        var cache = BoundedCache<String, Int>(capacity: 4)
        for (index, key) in ["r1/x", "r1/y", "r2/x", "r3/z"].enumerated() { cache.insert(index, for: key) }

        cache.removeValue(for: "r3/z")
        cache.removeAll { $0.hasPrefix("r1/") }

        XCTAssertEqual(cache.keys, ["r2/x"])
        XCTAssertEqual(cache.count, 1)
    }
}
