import XCTest
import VectorSwift

final class IntegrationTests: XCTestCase {

    func testDatabaseEndToEnd() async throws {
        let db = try await Database.open()

        try await db.createCollection(CollectionConfig(
            name: "docs",
            dimension: 2,
            metric: .l2
        ))
        try await db.createCollection(CollectionConfig(
            name: "tags",
            dimension: 2,
            metric: .cosine,
            normalizeVectors: true
        ))

        let listed = try await db.listCollections()
        XCTAssertEqual(listed, ["docs", "tags"])

        let docs = try await db.collection(name: "docs")
        try await docs.upsert([
            Point(id: "a", vector: [0, 0], payload: ["k": .string("v")]),
            Point(id: "b", vector: [3, 4]),
        ])
        try await docs.upsert([
            Point(id: "a", vector: [1, 0], payload: ["k": .string("replaced")]),
        ])
        await docs.delete(ids: ["b"])

        let got = await docs.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].vector, [1, 0])
        XCTAssertEqual(got[0].payload["k"], .string("replaced"))

        let hits = try await docs.search(
            SearchRequest(vector: [1, 0], k: 5, withPayload: true, withVector: true)
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, "a")
        XCTAssertEqual(hits[0].distance, 0, accuracy: 1e-5)
        XCTAssertEqual(hits[0].payload?["k"], .string("replaced"))
        XCTAssertEqual(hits[0].vector, [1, 0])

        let tags = try await db.collection(name: "tags")
        try await tags.upsert([Point(id: "t1", vector: [2, 0])])
        let tagHits = try await tags.search(SearchRequest(vector: [1, 0], k: 1))
        XCTAssertEqual(tagHits[0].id, "t1")
        XCTAssertEqual(tagHits[0].distance, 0, accuracy: 1e-5)

        try await db.checkpoint()
        try await db.dropCollection(name: "tags")
        let afterDrop = try await db.listCollections()
        XCTAssertEqual(afterDrop, ["docs"])

        try await db.close()
        do {
            _ = try await db.listCollections()
            XCTFail("expected closed")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testUnsupportedIndexRejected() async throws {
        let db = try await Database.open()
        do {
            try await db.createCollection(CollectionConfig(
                name: "approx",
                dimension: 2,
                metric: .l2,
                index: .hnsw,
                hnsw: .default
            ))
            XCTFail("expected unsupported index")
        } catch let error as VectorSwiftError {
            guard case .invalidArgument(let message) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(message.contains("flat"), message)
        }
        try await db.close()
    }
}
