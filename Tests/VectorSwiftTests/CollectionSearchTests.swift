import XCTest
import VectorSwift

final class CollectionSearchTests: XCTestCase {
    private let accuracy: Float = 1e-5

    private func makeCollection(
        dimension: Int = 2,
        metric: DistanceMetric = .l2,
        normalize: Bool = false
    ) throws -> Collection {
        try Collection(
            config: CollectionConfig(
                name: "search-docs",
                dimension: dimension,
                metric: metric,
                normalizeVectors: normalize
            )
        )
    }

    func testEmptyCollectionReturnsEmpty() async throws {
        let col = try makeCollection()
        let hits = try await col.search(SearchRequest(vector: [0, 0], k: 3))
        XCTAssertEqual(hits, [])
    }

    func testNearestNeighborL2() async throws {
        let col = try makeCollection(metric: .l2)
        try await col.upsert([
            Point(id: "origin", vector: [0, 0]),
            Point(id: "far", vector: [10, 0]),
            Point(id: "near", vector: [1, 0]),
        ])
        let hits = try await col.search(SearchRequest(vector: [0, 0], k: 2, withPayload: false))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].id, "origin")
        XCTAssertEqual(hits[0].distance, 0, accuracy: accuracy)
        XCTAssertEqual(hits[1].id, "near")
        XCTAssertEqual(hits[1].distance, 1, accuracy: accuracy)
        // Nondecreasing distances
        XCTAssertLessThanOrEqual(hits[0].distance, hits[1].distance)
    }

    func testKLargerThanCountReturnsAll() async throws {
        let col = try makeCollection()
        try await col.upsert([
            Point(id: "a", vector: [0, 0]),
            Point(id: "b", vector: [1, 0]),
        ])
        let hits = try await col.search(SearchRequest(vector: [0, 0], k: 50))
        XCTAssertEqual(hits.count, 2)
    }

    func testWithPayloadAndVectorFlags() async throws {
        let col = try makeCollection()
        try await col.upsert([
            Point(id: "a", vector: [1, 0], payload: ["t": .string("x")]),
        ])

        let withBoth = try await col.search(
            SearchRequest(vector: [1, 0], k: 1, withPayload: true, withVector: true)
        )
        XCTAssertEqual(withBoth[0].payload?["t"], .string("x"))
        XCTAssertEqual(withBoth[0].vector, [1, 0])

        let bare = try await col.search(
            SearchRequest(vector: [1, 0], k: 1, withPayload: false, withVector: false)
        )
        XCTAssertNil(bare[0].payload)
        XCTAssertNil(bare[0].vector)
    }

    func testDeletedPointsExcluded() async throws {
        let col = try makeCollection()
        try await col.upsert([
            Point(id: "keep", vector: [2, 0]),
            Point(id: "gone", vector: [0, 0]),
        ])
        await col.delete(ids: ["gone"])
        let hits = try await col.search(SearchRequest(vector: [0, 0], k: 5))
        XCTAssertEqual(hits.map(\.id), ["keep"])
    }

    func testWrongQueryDimensionThrows() async throws {
        let col = try makeCollection(dimension: 2)
        try await col.upsert([Point(id: "a", vector: [0, 0])])
        do {
            _ = try await col.search(SearchRequest(vector: [0, 0, 0], k: 1))
            XCTFail("expected throw")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .invalidDimension(expected: 2, actual: 3))
        }
    }

    func testInvalidKThrows() async throws {
        let col = try makeCollection()
        try await col.upsert([Point(id: "a", vector: [0, 0])])
        do {
            _ = try await col.search(SearchRequest(vector: [0, 0], k: 0))
            XCTFail("expected throw")
        } catch let error as VectorSwiftError {
            guard case .invalidArgument = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testAllMetricsReturnSortedResults() async throws {
        let points = [
            Point(id: "a", vector: [1, 0]),
            Point(id: "b", vector: [0, 1]),
            Point(id: "c", vector: [0.7, 0.7]),
        ]
        for metric in DistanceMetric.allCases {
            let col = try makeCollection(metric: metric)
            try await col.upsert(points)
            let hits = try await col.search(SearchRequest(vector: [1, 0], k: 3))
            XCTAssertEqual(hits.count, 3, "metric \(metric)")
            for i in 1..<hits.count {
                XCTAssertLessThanOrEqual(
                    hits[i - 1].distance,
                    hits[i].distance,
                    "metric \(metric) not sorted"
                )
            }
            // For L2 / cosine / IP on [1,0], "a" should be nearest among these.
            if metric == .l2 || metric == .l2Squared || metric == .cosine || metric == .innerProduct {
                XCTAssertEqual(hits[0].id, "a", "metric \(metric)")
            }
        }
    }

    func testCosineWithNormalize() async throws {
        let col = try makeCollection(metric: .cosine, normalize: true)
        try await col.upsert([
            Point(id: "same", vector: [2, 0]),   // stored as [1, 0]
            Point(id: "ortho", vector: [0, 3]),  // stored as [0, 1]
        ])
        let hits = try await col.search(SearchRequest(vector: [4, 0], k: 2))
        XCTAssertEqual(hits[0].id, "same")
        XCTAssertEqual(hits[0].distance, 0, accuracy: accuracy)
        XCTAssertEqual(hits[1].id, "ortho")
        XCTAssertEqual(hits[1].distance, 1, accuracy: accuracy)
    }

    func testReplaceUpdatesSearchResults() async throws {
        let col = try makeCollection()
        try await col.upsert([Point(id: "x", vector: [100, 0])])
        try await col.upsert([Point(id: "x", vector: [0, 0])])
        let hits = try await col.search(SearchRequest(vector: [0, 0], k: 1))
        XCTAssertEqual(hits[0].id, "x")
        XCTAssertEqual(hits[0].distance, 0, accuracy: accuracy)
    }
}
