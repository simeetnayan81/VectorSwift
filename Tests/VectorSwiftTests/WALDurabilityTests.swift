import XCTest
import Foundation
import VectorSwift
import VectorSwiftStorage

/// Integration tests: path-backed upsert/delete survive reopen via WAL (S13).
final class WALDurabilityTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStrictUpsertSurvivesReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await Database.open(
                path: root,
                config: DatabaseConfig(durability: .strict, compute: .cpu)
            )
            try await db.createCollection(CollectionConfig(
                name: "docs",
                dimension: 3,
                metric: .l2
            ))
            let col = try await db.collection(name: "docs")
            try await col.upsert([
                Point(id: "a", vector: [1, 0, 0], payload: ["t": .string("A")]),
                Point(id: "b", vector: [0, 1, 0], payload: ["t": .string("B")]),
            ])
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.walLog(collection: "docs").path))

        let reopened = try await Database.open(path: root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 2)

        let got = await col.get(ids: ["a", "b"], withVector: true)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].vector, [1, 0, 0])
        XCTAssertEqual(got[0].payload["t"], .string("A"))
        XCTAssertEqual(got[1].vector, [0, 1, 0])

        let hits = try await col.search(SearchRequest(vector: [1, 0, 0], k: 1, withPayload: true))
        XCTAssertEqual(hits[0].id, "a")
        XCTAssertEqual(hits[0].payload?["t"], .string("A"))

        try await reopened.close()
    }

    func testReplaceLastWriteWinsAfterReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([Point(id: "x", vector: [1, 0], payload: ["v": .int(1)])])
        try await col.upsert([Point(id: "x", vector: [0, 1], payload: ["v": .int(2)])])
        try await db.close()

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let got = await again.get(ids: ["x"], withVector: true)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].vector, [0, 1])
        XCTAssertEqual(got[0].payload["v"], .int(2))
        let count = await again.count()
        XCTAssertEqual(count, 1)
        try await reopened.close()
    }

    func testDeleteSurvivesReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([
            Point(id: "keep", vector: [1, 0]),
            Point(id: "drop", vector: [0, 1]),
        ])
        try await col.delete(ids: ["drop"])
        let live = await col.count()
        let withTomb = await col.count(includeTombstones: true)
        XCTAssertEqual(live, 1)
        XCTAssertEqual(withTomb, 2)
        try await db.close()

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let live2 = await again.count()
        XCTAssertEqual(live2, 1)
        let dropped = await again.get(ids: ["drop"])
        XCTAssertEqual(dropped.count, 0)
        let kept = await again.get(ids: ["keep"], withVector: true)
        XCTAssertEqual(kept[0].vector, [1, 0])
        let withTomb2 = await again.count(includeTombstones: true)
        XCTAssertEqual(withTomb2, 2)
        try await reopened.close()
    }

    func testNormalizeOnUpsertStoredAndReplayed() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(
            name: "docs",
            dimension: 2,
            metric: .cosine,
            normalizeVectors: true
        ))
        let col = try await db.collection(name: "docs")
        try await col.upsert([Point(id: "n", vector: [3, 4])])
        let before = await col.get(ids: ["n"], withVector: true)
        XCTAssertEqual(before[0].vector[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(before[0].vector[1], 0.8, accuracy: 1e-5)
        try await db.close()

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let after = await again.get(ids: ["n"], withVector: true)
        XCTAssertEqual(after[0].vector[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(after[0].vector[1], 0.8, accuracy: 1e-5)
        try await reopened.close()
    }

    func testTornWALTailDiscardedOnOpen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([Point(id: "good", vector: [1, 2])])
        try await db.close()

        let layout = DatabaseLayout(root: root)
        let walURL = layout.walLog(collection: "docs")
        let goodSize = try Data(contentsOf: walURL).count

        // Append incomplete tail
        var partial = Data()
        BinaryIO.appendUInt32(50, to: &partial)
        partial.append(contentsOf: [1, 2, 3])
        let handle = try FileHandle(forWritingTo: walURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: partial)
        try handle.close()
        let inflated = try Data(contentsOf: walURL).count
        XCTAssertGreaterThan(inflated, goodSize)

        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let count = await again.count()
        XCTAssertEqual(count, 1)
        let got = await again.get(ids: ["good"], withVector: true)
        XCTAssertEqual(got[0].vector, [1, 2])
        // Tail should have been truncated during open/replay
        let truncated = try Data(contentsOf: walURL).count
        XCTAssertEqual(truncated, goodSize)
        try await reopened.close()
    }

    func testBalancedAlsoPersistsAcrossReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .balanced, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([Point(id: "p", vector: [5, 6])])
        try await db.close()

        let reopened = try await Database.open(path: root)
        let col = try await reopened.collection(name: "docs")
        let got = await col.get(ids: ["p"], withVector: true)
        XCTAssertEqual(got[0].vector, [5, 6])
        try await reopened.close()
    }

    func testEphemeralDatabaseHasNoWAL() async throws {
        let db = try await Database.open(config: DatabaseConfig(durability: .strict, compute: .cpu))
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([Point(id: "a", vector: [1, 0])])
        let path = await db.storagePath
        XCTAssertNil(path)
        try await db.close()
    }

    func testCheckpointWritesMark() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([Point(id: "a", vector: [1, 0])])
        try await db.checkpoint()
        try await db.close()

        let wal = WriteAheadLog(url: DatabaseLayout(root: root).walLog(collection: "docs"))
        let records = try wal.readAllValidRecords()
        XCTAssertTrue(records.contains(.checkpointMark))
        let upserts = records.filter {
            if case .upsert = $0 { return true }
            return false
        }
        XCTAssertEqual(upserts.count, 1)
    }

    func testBatchUpsertAllPresentAfterReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let points = (0..<20).map { i in
            Point(id: "id-\(i)", vector: [Float(i), Float(i + 1)], payload: ["i": .int(Int64(i))])
        }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert(points)
        try await db.close()

        let reopened = try await Database.open(path: root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 20)
        let got = await col.get(ids: points.map(\.id), withVector: true)
        XCTAssertEqual(got.count, 20)
        XCTAssertEqual(got[19].vector, [19, 20])
        try await reopened.close()
    }
}
