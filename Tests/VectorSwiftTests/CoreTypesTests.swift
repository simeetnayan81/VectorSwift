import XCTest
import VectorSwift

final class CoreTypesTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    func testPointCodableRoundTrip() throws {
        let point = Point(
            id: "doc-1",
            vector: [0.1, 0.2, 0.3],
            payload: [
                "lang": .string("en"),
                "score": .double(1.5),
                "count": .int(42),
                "ok": .bool(true),
                "tags": .strings(["a", "b"]),
                "empty": .null,
            ]
        )
        let data = try encoder.encode(point)
        let decoded = try decoder.decode(Point.self, from: data)
        XCTAssertEqual(decoded, point)
    }

    func testScoredPointEquatableAndCodable() throws {
        let a = ScoredPoint(id: "x", distance: 0.25, payload: ["k": .int(1)], vector: [1, 2])
        let b = ScoredPoint(id: "x", distance: 0.25, payload: ["k": .int(1)], vector: [1, 2])
        XCTAssertEqual(a, b)
        let decoded = try decoder.decode(ScoredPoint.self, from: try encoder.encode(a))
        XCTAssertEqual(decoded, a)
    }

    func testCollectionConfigCodableRoundTrip() throws {
        let config = CollectionConfig(
            name: "docs",
            dimension: 384,
            metric: .cosine,
            index: .hnsw,
            normalizeVectors: true,
            hnsw: HNSWParams(m: 16, efConstruction: 200, efSearch: 64, maxM0: 32, seed: 7)
        )
        let decoded = try decoder.decode(CollectionConfig.self, from: try encoder.encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.hnsw?.resolvedMaxM0, 32)
    }

    func testHNSWParamsResolvedMaxM0Default() {
        let params = HNSWParams(m: 16, maxM0: nil)
        XCTAssertEqual(params.resolvedMaxM0, 32)
        XCTAssertEqual(HNSWParams.default.m, 16)
        XCTAssertEqual(HNSWParams.default.efConstruction, 200)
        XCTAssertEqual(HNSWParams.default.efSearch, 64)
    }

    func testDatabaseConfigDefaultsAndCodable() throws {
        let config = DatabaseConfig.default
        XCTAssertEqual(config.durability, .balanced)
        XCTAssertEqual(config.compute, .auto)
        XCTAssertEqual(config.mutableSegmentMaxPoints, 10_000)
        XCTAssertEqual(config.mutableSegmentMaxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(config.tombstoneRatioCompact, 0.20, accuracy: 1e-12)

        let decoded = try decoder.decode(DatabaseConfig.self, from: try encoder.encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testFilterNestedCodableRoundTrip() throws {
        let filter: Filter = .and([
            .eq("lang", .string("en")),
            .or([
                .gte("year", .int(2024)),
                .in("tag", [.string("a"), .string("b")]),
            ]),
            .not(.eq("draft", .bool(true))),
        ])
        let decoded = try decoder.decode(Filter.self, from: try encoder.encode(filter))
        XCTAssertEqual(decoded, filter)
    }

    func testSearchRequestCodableRoundTrip() throws {
        let request = SearchRequest(
            vector: [1, 0, 0],
            k: 10,
            filter: .eq("lang", .string("en")),
            ef: 64,
            withPayload: true,
            withVector: false
        )
        let decoded = try decoder.decode(SearchRequest.self, from: try encoder.encode(request))
        XCTAssertEqual(decoded, request)
    }

    func testDistanceMetricAndIndexConfigRawValues() {
        XCTAssertEqual(DistanceMetric.l2.rawValue, "l2")
        XCTAssertEqual(DistanceMetric.allCases.count, 4)
        XCTAssertEqual(IndexConfig.flat.rawValue, "flat")
        XCTAssertEqual(IndexConfig.hnsw.rawValue, "hnsw")
    }

    func testVectorSwiftErrorEquality() {
        XCTAssertEqual(
            VectorSwiftError.invalidDimension(expected: 3, actual: 2),
            VectorSwiftError.invalidDimension(expected: 3, actual: 2)
        )
        XCTAssertNotEqual(
            VectorSwiftError.collectionNotFound("a"),
            VectorSwiftError.collectionNotFound("b")
        )
        XCTAssertEqual(VectorSwiftError.closed.description, "Database is closed")
    }

    func testLimitsConstants() {
        XCTAssertEqual(VectorSwiftLimits.maxPointIDUTF8ByteCount, 512)
        XCTAssertEqual(VectorSwiftLimits.maxCollectionNameUTF8ByteCount, 128)
    }
}
