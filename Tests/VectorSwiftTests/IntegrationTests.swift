import XCTest
import Foundation
import VectorSwift
import VectorSwiftStorage

final class IntegrationTests: XCTestCase {

    private func tempRoot(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertPayloadEqual(
        _ actual: [String: PayloadValue],
        _ expected: [String: PayloadValue],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (key, value) in expected {
            XCTAssertEqual(actual[key], value, "payload[\(key)]", file: file, line: line)
        }
    }

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
        try await docs.delete(ids: ["b"])

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

    /// Path-backed payloads survive WAL reopen, seal-from-segments, search, and last-write-wins supersede.
    func testPayloadPersistsAcrossWALSealAndReopen() async throws {
        let root = try tempRoot("payload-gate")
        defer { try? FileManager.default.removeItem(at: root) }

        let fullPayload: [String: PayloadValue] = [
            "n": .null,
            "b": .bool(true),
            "i": .int(-42),
            "d": .double(3.5),
            "s": .string("hello"),
            "ss": .strings(["a", "b"]),
        ]
        let vector: [Float] = [1, 0]

        do {
            let db = try await Database.open(
                path: root,
                config: DatabaseConfig(durability: .strict, compute: .cpu)
            )
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "p", vector: vector, payload: fullPayload)])
            try await db.close()
        }

        // Reopen via WAL (no seal yet).
        do {
            let db = try await Database.open(path: root)
            let col = try await db.collection(name: "docs")
            let got = await col.get(ids: ["p"], withVector: true)
            XCTAssertEqual(got.count, 1)
            XCTAssertEqual(got[0].vector, vector)
            assertPayloadEqual(got[0].payload, fullPayload)

            let hits = try await col.search(
                SearchRequest(vector: [1, 0], k: 1, withPayload: true, withVector: true)
            )
            XCTAssertEqual(hits.count, 1)
            XCTAssertEqual(hits[0].id, "p")
            XCTAssertEqual(hits[0].vector, vector)
            assertPayloadEqual(hits[0].payload ?? [:], fullPayload)

            try await db.checkpoint()
            let layout = DatabaseLayout(root: root)
            let walSize = try Data(contentsOf: layout.walLog(collection: "docs")).count
            XCTAssertEqual(walSize, 0, "WAL must be empty after successful seal")
            XCTAssertTrue(JSONFileStore.exists(layout.manifest(collection: "docs")))
            try await db.close()
        }

        // Reopen from sealed segments only (empty WAL).
        do {
            let db = try await Database.open(path: root)
            let col = try await db.collection(name: "docs")
            let got = await col.get(ids: ["p"], withVector: true)
            XCTAssertEqual(got.count, 1)
            XCTAssertEqual(got[0].vector, vector)
            assertPayloadEqual(got[0].payload, fullPayload)

            let hits = try await col.search(
                SearchRequest(vector: [1, 0], k: 1, withPayload: true)
            )
            XCTAssertEqual(hits[0].id, "p")
            assertPayloadEqual(hits[0].payload ?? [:], fullPayload)

            // Supersede with a different payload; seal again.
            let replaced: [String: PayloadValue] = [
                "s": .string("replaced"),
                "i": .int(99),
            ]
            try await col.upsert([Point(id: "p", vector: [0, 1], payload: replaced)])
            try await db.checkpoint()
            try await db.close()
        }

        let db = try await Database.open(path: root)
        let col = try await db.collection(name: "docs")
        let got = await col.get(ids: ["p"], withVector: true)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].vector, [0, 1])
        assertPayloadEqual(got[0].payload, [
            "s": .string("replaced"),
            "i": .int(99),
        ])
        XCTAssertNil(got[0].payload["n"], "supersede replaces entire payload map")
        try await db.close()
    }
}
