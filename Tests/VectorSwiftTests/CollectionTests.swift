import XCTest
import VectorSwift

final class CollectionTests: XCTestCase {

    private func makeCollection(
        dimension: Int = 3,
        normalize: Bool = false,
        name: String = "docs"
    ) throws -> Collection {
        try Collection(
            config: CollectionConfig(
                name: name,
                dimension: dimension,
                metric: .l2,
                normalizeVectors: normalize
            )
        )
    }

    func testUpsertAndGet() async throws {
        let col = try makeCollection()
        try await col.upsert([
            Point(id: "a", vector: [1, 2, 3], payload: ["k": .string("v")]),
        ])
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].id, "a")
        XCTAssertEqual(got[0].vector, [1, 2, 3])
        XCTAssertEqual(got[0].payload["k"], .string("v"))
    }

    func testGetWithoutVectorClearsVector() async throws {
        let col = try makeCollection()
        try await col.upsert([Point(id: "a", vector: [1, 0, 0])])
        let got = await col.get(ids: ["a"], withVector: false)
        XCTAssertEqual(got[0].vector, [])
        XCTAssertEqual(got[0].id, "a")
    }

    func testGetPreservesRequestOrderAndSkipsMissing() async throws {
        let col = try makeCollection()
        try await col.upsert([
            Point(id: "a", vector: [1, 0, 0]),
            Point(id: "b", vector: [0, 1, 0]),
        ])
        let got = await col.get(ids: ["b", "missing", "a"], withVector: true)
        XCTAssertEqual(got.map(\.id), ["b", "a"])
    }

    func testUpsertReplacesSameId() async throws {
        let col = try makeCollection()
        try await col.upsert([Point(id: "a", vector: [1, 0, 0], payload: ["v": .int(1)])])
        try await col.upsert([Point(id: "a", vector: [0, 1, 0], payload: ["v": .int(2)])])
        let live = await col.count()
        XCTAssertEqual(live, 1)
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got[0].vector, [0, 1, 0])
        XCTAssertEqual(got[0].payload["v"], .int(2))
    }

    func testDeleteHidesFromGetAndCount() async throws {
        let col = try makeCollection()
        try await col.upsert([
            Point(id: "a", vector: [1, 0, 0]),
            Point(id: "b", vector: [0, 1, 0]),
        ])
        await col.delete(ids: ["a"])
        let live = await col.count()
        let withTomb = await col.count(includeTombstones: true)
        XCTAssertEqual(live, 1)
        XCTAssertEqual(withTomb, 2)
        let got = await col.get(ids: ["a", "b"], withVector: true)
        XCTAssertEqual(got.map(\.id), ["b"])
    }

    func testDeleteUnknownIdIsNoOp() async throws {
        let col = try makeCollection()
        try await col.upsert([Point(id: "a", vector: [1, 0, 0])])
        await col.delete(ids: ["nope"])
        let live = await col.count()
        let withTomb = await col.count(includeTombstones: true)
        XCTAssertEqual(live, 1)
        XCTAssertEqual(withTomb, 1)
    }

    func testEmptyUpsertNoOp() async throws {
        let col = try makeCollection()
        try await col.upsert([])
        let live = await col.count()
        XCTAssertEqual(live, 0)
    }

    func testInvalidPointIDEmpty() async throws {
        let col = try makeCollection()
        do {
            try await col.upsert([Point(id: "", vector: [1, 0, 0])])
            XCTFail("expected throw")
        } catch let error as VectorSwiftError {
            guard case .invalidPointID = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testInvalidPointIDTooLong() async throws {
        let col = try makeCollection()
        let longID = String(repeating: "x", count: VectorSwiftLimits.maxPointIDUTF8ByteCount + 1)
        do {
            try await col.upsert([Point(id: longID, vector: [1, 0, 0])])
            XCTFail("expected throw")
        } catch let error as VectorSwiftError {
            guard case .invalidPointID = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testInvalidDimension() async throws {
        let col = try makeCollection(dimension: 3)
        do {
            try await col.upsert([Point(id: "a", vector: [1, 2])])
            XCTFail("expected throw")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .invalidDimension(expected: 3, actual: 2))
        }
    }

    func testNormalizeOnUpsert() async throws {
        let col = try makeCollection(normalize: true)
        try await col.upsert([Point(id: "a", vector: [3, 0, 0])])
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got[0].vector[0], 1, accuracy: 1e-5)
        XCTAssertEqual(got[0].vector[1], 0, accuracy: 1e-5)
        XCTAssertEqual(got[0].vector[2], 0, accuracy: 1e-5)
    }

    func testNormalizeRejectsZeroVector() async throws {
        let col = try makeCollection(normalize: true)
        do {
            try await col.upsert([Point(id: "a", vector: [0, 0, 0])])
            XCTFail("expected throw")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .zeroVectorNotAllowed)
        }
    }

    func testInvalidCollectionConfig() {
        XCTAssertThrowsError(
            try Collection(config: CollectionConfig(name: "", dimension: 3, metric: .l2))
        )
        XCTAssertThrowsError(
            try Collection(config: CollectionConfig(name: "ok", dimension: 0, metric: .l2))
        )
    }

    func testCheckpointNoOp() async throws {
        let col = try makeCollection()
        try await col.upsert([Point(id: "a", vector: [1, 0, 0])])
        await col.checkpoint()
        let live = await col.count()
        XCTAssertEqual(live, 1)
    }

    func testNameAndConfig() async throws {
        let col = try makeCollection(name: "articles")
        XCTAssertEqual(col.name, "articles")
        let cfg = await col.config
        XCTAssertEqual(cfg.dimension, 3)
        XCTAssertEqual(cfg.metric, .l2)
    }
}
