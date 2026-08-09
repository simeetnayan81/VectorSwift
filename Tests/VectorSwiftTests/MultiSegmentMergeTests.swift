import XCTest
import VectorSwiftCore
import VectorSwiftQuery

final class MultiSegmentMergeTests: XCTestCase {
    private func hit(_ id: String, _ distance: Float) -> ScoredPoint {
        ScoredPoint(id: id, distance: distance)
    }

    func testEmptyParts() {
        XCTAssertEqual(MultiSegmentMerge.topK([], k: 3), [])
        XCTAssertEqual(MultiSegmentMerge.topK([[], []], k: 3), [])
    }

    func testInvalidK() {
        XCTAssertEqual(MultiSegmentMerge.topK([[hit("a", 1)]], k: 0), [])
    }

    func testKOneTakesGlobalBest() {
        let parts: [[ScoredPoint]] = [
            [hit("a", 2), hit("b", 4)],
            [hit("c", 0.5), hit("d", 3)],
        ]
        let got = MultiSegmentMerge.topK(parts, k: 1)
        XCTAssertEqual(got.map(\.id), ["c"])
    }

    func testKLargerThanTotalReturnsAllSorted() {
        let parts: [[ScoredPoint]] = [
            [hit("b", 2)],
            [hit("a", 1), hit("c", 3)],
        ]
        let got = MultiSegmentMerge.topK(parts, k: 50)
        XCTAssertEqual(got.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(got.map(\.distance), [1, 2, 3])
    }

    func testTieBreakById() {
        let parts: [[ScoredPoint]] = [
            [hit("b", 1)],
            [hit("a", 1)],
        ]
        let got = MultiSegmentMerge.topK(parts, k: 2)
        XCTAssertEqual(got.map(\.id), ["a", "b"])
    }

    func testDuplicateIdKeptOnce() {
        let parts: [[ScoredPoint]] = [
            [hit("a", 2)],
            [hit("a", 2), hit("b", 3)],
        ]
        let got = MultiSegmentMerge.topK(parts, k: 5)
        XCTAssertEqual(got.map(\.id), ["a", "b"])
    }
}
