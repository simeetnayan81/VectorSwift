import XCTest
import Foundation
import VectorSwift
import VectorSwiftCore
import VectorSwiftStorage

/// Incremental seal + multi-segment search.
final class MultiSegmentSearchTests: XCTestCase {

    private func tempRoot(_ label: String = "ms") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func point(_ id: String, x: Float, y: Float = 0, payload: [String: PayloadValue] = [:]) -> Point {
        Point(id: id, vector: [x, y], payload: payload)
    }

    private func openDB(
        root: URL,
        maxPoints: Int = 2
    ) async throws -> Database {
        try await Database.open(
            path: root,
            config: DatabaseConfig(
                durability: .strict,
                compute: .cpu,
                mutableSegmentMaxPoints: maxPoints,
                mutableSegmentMaxBytes: 64 * 1024 * 1024
            )
        )
    }

    func testAutoSealYieldsMultipleSegmentsAndCorrectSearch() async throws {
        let root = try tempRoot("auto")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await openDB(root: root, maxPoints: 2)
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        for p in [
            point("a", x: 1),
            point("b", x: 2),
            point("c", x: 3),
            point("d", x: 4),
            point("e", x: 5),
        ] {
            try await col.upsert([p])
        }
        try await db.checkpoint()
        let layout = DatabaseLayout(root: root)
        let manifest = try JSONFileStore.read(
            ManifestDocument.self,
            from: layout.manifest(collection: "docs")
        )
        XCTAssertGreaterThanOrEqual(manifest.segmentIds.count, 2)
        XCTAssertEqual(
            try Data(contentsOf: layout.walLog(collection: "docs")).count,
            0
        )

        let hits = try await col.search(SearchRequest(vector: [1, 0], k: 3))
        XCTAssertEqual(hits.map(\.id), ["a", "b", "c"])
        try await db.close()

        let again = try await Database.open(path: root)
        let againCol = try await again.collection(name: "docs")
        let count = await againCol.count()
        XCTAssertEqual(count, 5)
        let againHits = try await againCol.search(SearchRequest(vector: [1, 0], k: 3))
        XCTAssertEqual(againHits.map(\.id), ["a", "b", "c"])
        try await again.close()
    }

    func testLaterSegmentSupersedesSameId() async throws {
        let root = try tempRoot("lww")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await openDB(root: root, maxPoints: 10_000)
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("a", x: 1, payload: ["v": .int(1)])])
        try await db.checkpoint()
        try await col.upsert([point("a", x: 9, payload: ["v": .int(2)]), point("b", x: 0)])
        try await db.checkpoint()
        try await db.close()

        let layout = DatabaseLayout(root: root)
        let manifest = try JSONFileStore.read(
            ManifestDocument.self,
            from: layout.manifest(collection: "docs")
        )
        XCTAssertEqual(manifest.segmentIds.count, 2)
        let firstIds = try IdSegmentFile.read(
            from: layout.idsBin(collection: "docs", segmentId: manifest.segmentIds[0])
        )
        XCTAssertEqual(Set(firstIds.ids), Set(["a"]))

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let got = await again.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].vector, [9, 0])
        XCTAssertEqual(got[0].payload["v"], .int(2))
        let hits = try await again.search(
            SearchRequest(vector: [9, 0], k: 2, withPayload: true, withVector: true)
        )
        XCTAssertEqual(hits.first?.id, "a")
        XCTAssertEqual(hits.first?.vector, [9, 0])
        try await reopened.close()
    }

    func testDeleteSealedIdSurvivesSealAndReopen() async throws {
        let root = try tempRoot("del")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await openDB(root: root)
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("keep", x: 1), point("drop", x: 2)])
        try await db.checkpoint()
        try await col.delete(ids: ["drop"])
        try await db.checkpoint()
        try await db.close()

        let layout = DatabaseLayout(root: root)
        XCTAssertEqual(try Data(contentsOf: layout.walLog(collection: "docs")).count, 0)
        let manifest = try JSONFileStore.read(
            ManifestDocument.self,
            from: layout.manifest(collection: "docs")
        )
        XCTAssertEqual(manifest.segmentIds.count, 2)
        let tombs = try IdSegmentFile.read(
            from: layout.tombstonesBin(collection: "docs", segmentId: manifest.segmentIds[1])
        )
        XCTAssertEqual(Set(tombs.ids), Set(["drop"]))

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let count = await again.count()
        XCTAssertEqual(count, 1)
        let got = await again.get(ids: ["keep", "drop"], withVector: true)
        XCTAssertEqual(got.map(\.id), ["keep"])
        let hits = try await again.search(SearchRequest(vector: [2, 0], k: 5))
        XCTAssertEqual(hits.map(\.id), ["keep"])
        try await reopened.close()
    }

    func testDeleteThenReupsertResurrects() async throws {
        let root = try tempRoot("rez")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await openDB(root: root)
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("a", x: 1)])
        try await db.checkpoint()
        try await col.delete(ids: ["a"])
        try await col.upsert([point("a", x: 8)])
        try await db.checkpoint()
        try await db.close()

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let got = await again.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got[0].vector, [8, 0])
        let hits = try await again.search(SearchRequest(vector: [8, 0], k: 1))
        XCTAssertEqual(hits.map(\.id), ["a"])
        try await reopened.close()
    }

    func testMutablePointsVisibleWithoutSecondSeal() async throws {
        let root = try tempRoot("mut")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await openDB(root: root, maxPoints: 10_000)
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("a", x: 0)])
        try await db.checkpoint()
        try await col.upsert([point("b", x: 10)])

        let hits = try await col.search(SearchRequest(vector: [10, 0], k: 1))
        XCTAssertEqual(hits.map(\.id), ["b"])
        XCTAssertGreaterThan(
            try Data(contentsOf: DatabaseLayout(root: root).walLog(collection: "docs")).count,
            0
        )
        try await db.close()
    }

    func testKSpansSegments() async throws {
        let root = try tempRoot("kspan")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await openDB(root: root, maxPoints: 2)
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2Squared))
        let col = try await db.collection(name: "docs")
        for p in [
            point("a", x: 0),
            point("b", x: 1),
            point("c", x: 2),
            point("d", x: 3),
        ] {
            try await col.upsert([p])
        }
        let hits = try await col.search(SearchRequest(vector: [0, 0], k: 3))
        XCTAssertEqual(hits.map(\.id), ["a", "b", "c"])
        try await db.close()
    }

    func testInMemorySearchUnchanged() async throws {
        let db = try await Database.open(config: DatabaseConfig(durability: .strict, compute: .cpu))
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("a", x: 1), point("b", x: 5)])
        try await db.checkpoint()
        let hits = try await col.search(SearchRequest(vector: [1, 0], k: 1))
        XCTAssertEqual(hits.map(\.id), ["a"])
        try await db.close()
    }
}
