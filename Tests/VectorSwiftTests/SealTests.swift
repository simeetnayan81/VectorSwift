import XCTest
import Foundation
import VectorSwift
import VectorSwiftCore
import VectorSwiftStorage

/// Sealed segment materialization, MANIFEST, and recovery from segment files.
final class SealTests: XCTestCase {

    private func tempRoot(_ label: String = "seal") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func point(_ id: String, x: Float = 1, y: Float = 0, payload: [String: PayloadValue] = [:]) -> Point {
        Point(id: id, vector: [x, y], payload: payload)
    }

    // MARK: - PAYLOAD.bin

    func testPayloadSegmentRoundTrip() throws {
        let file = PayloadSegmentFile(payloads: [
            [:],
            ["k": .string("v"), "n": .int(3)],
            ["tags": .strings(["a", "b"])],
        ])
        let encoded = try PayloadSegmentFile.encode(file)
        let decoded = try PayloadSegmentFile.decode(encoded)
        XCTAssertEqual(decoded.payloads.count, 3)
        XCTAssertEqual(decoded.payloads[1]["k"], .string("v"))
        XCTAssertEqual(decoded.payloads[1]["n"], .int(3))
        XCTAssertEqual(decoded.payloads[2]["tags"], .strings(["a", "b"]))
    }

    func testPayloadCRCMismatchIsCorrupted() throws {
        var data = try PayloadSegmentFile.encode(PayloadSegmentFile(payloads: [["a": .bool(true)]]))
        // Flip trailer CRC
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try PayloadSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted = error else {
                return XCTFail("expected corrupted, got \(error)")
            }
        }
    }

    // MARK: - WAL seal_segment_v2

    func testSealSegmentV2CodecRoundTrip() throws {
        let seal = WALSealSegmentV2Payload(
            segmentId: 7,
            rowCount: 3,
            vectorsCrc32: 0x1111_2222,
            idsCrc32: 0x3333_4444,
            payloadsCrc32: 0x5555_6666,
            flags: 0
        )
        let frame = try WALCodec.encodeFrame(.sealSegmentV2(seal))
        let read = try WALCodec.readFrame(from: frame, at: 0)
        guard case .record(let record, _) = read else {
            return XCTFail("expected record")
        }
        XCTAssertEqual(record, .sealSegmentV2(seal))
    }

    func testLegacySealSegmentStillDecodes() throws {
        let frame = try WALCodec.encodeFrame(.sealSegment(segmentId: 42))
        let read = try WALCodec.readFrame(from: frame, at: 0)
        guard case .record(let record, _) = read else {
            return XCTFail("expected record")
        }
        XCTAssertEqual(record, .sealSegment(segmentId: 42))
    }

    func testWALResetEmpty() throws {
        let dir = try tempRoot("wal-reset")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wal = WriteAheadLog(url: dir.appendingPathComponent("wal.log"))
        try wal.append(.checkpointMark, sync: false)
        XCTAssertGreaterThan(try Data(contentsOf: wal.url).count, 0)
        try wal.resetEmpty()
        XCTAssertEqual(try Data(contentsOf: wal.url).count, 0)
        XCTAssertTrue(try wal.readAllValidRecords().isEmpty)
    }

    // MARK: - Checkpoint seal + reopen from segments

    func testCheckpointSealsAndReopenLoadsFromSegmentsOnly() async throws {
        let root = try tempRoot("cp-seal")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([
            point("a", x: 1, y: 0, payload: ["lang": .string("en")]),
            point("b", x: 0, y: 1, payload: ["lang": .string("fr")]),
        ])
        try await db.checkpoint()
        try await db.close()

        let layout = DatabaseLayout(root: root)
        let manifest = try JSONFileStore.read(
            ManifestDocument.self,
            from: layout.manifest(collection: "docs")
        )
        XCTAssertEqual(manifest.segmentIds.count, 1)
        let segmentId = try XCTUnwrap(manifest.segmentIds.first)

        // Segment files exist with matching row count.
        let vectors = try VectorSegmentFile.read(
            from: layout.vectorsBin(collection: "docs", segmentId: segmentId)
        )
        XCTAssertEqual(vectors.count, 2)
        let ids = try IdSegmentFile.read(
            from: layout.idsBin(collection: "docs", segmentId: segmentId)
        )
        XCTAssertEqual(Set(ids.ids), Set(["a", "b"]))
        let payloads = try PayloadSegmentFile.read(
            from: layout.payloadBin(collection: "docs", segmentId: segmentId)
        )
        XCTAssertEqual(payloads.count, 2)

        // WAL reclaimed after seal.
        let walData = try Data(contentsOf: layout.walLog(collection: "docs"))
        XCTAssertEqual(walData.count, 0, "WAL must be empty after successful seal")

        // Reopen without any WAL frames — data comes from segments.
        let reopened = try await Database.open(path: root)
        let again = try await reopened.collection(name: "docs")
        let count = await again.count()
        XCTAssertEqual(count, 2)
        let got = await again.get(ids: ["a", "b"], withVector: true)
        XCTAssertEqual(got.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: got.map { ($0.id, $0) })
        XCTAssertEqual(byId["a"]?.vector, [1, 0])
        XCTAssertEqual(byId["b"]?.vector, [0, 1])
        XCTAssertEqual(byId["a"]?.payload["lang"], .string("en"))
        XCTAssertEqual(byId["b"]?.payload["lang"], .string("fr"))
        try await reopened.close()
    }

    func testAutoSealOnPointThreshold() async throws {
        let root = try tempRoot("auto-n")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(
                durability: .balanced,
                compute: .cpu,
                mutableSegmentMaxPoints: 3,
                mutableSegmentMaxBytes: 64 * 1024 * 1024
            )
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("1")])
        try await col.upsert([point("2", x: 2)])
        // Not sealed yet.
        XCTAssertFalse(
            JSONFileStore.exists(DatabaseLayout(root: root).manifest(collection: "docs"))
        )
        try await col.upsert([point("3", x: 3)])
        // Threshold trip seals.
        XCTAssertTrue(
            JSONFileStore.exists(DatabaseLayout(root: root).manifest(collection: "docs"))
        )
        let walSize = try Data(contentsOf: DatabaseLayout(root: root).walLog(collection: "docs")).count
        XCTAssertEqual(walSize, 0)
        try await db.close()

        let reopened = try await Database.open(path: root)
        let reopenedCol = try await reopened.collection(name: "docs")
        let count = await reopenedCol.count()
        XCTAssertEqual(count, 3)
        try await reopened.close()
    }

    func testExplicitSealAPI() async throws {
        let root = try tempRoot("seal-api")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .relaxed, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([point("z")])
        try await db.collection(name: "docs").seal()
        try await db.close()

        let layout = DatabaseLayout(root: root)
        XCTAssertTrue(JSONFileStore.exists(layout.manifest(collection: "docs")))
        XCTAssertEqual(try Data(contentsOf: layout.walLog(collection: "docs")).count, 0)
    }

    func testPostSealMutationSurvivesReopenViaWALThenSecondSeal() async throws {
        let root = try tempRoot("post-seal")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([point("a")])
        try await db.checkpoint()
        try await db.collection(name: "docs").upsert([point("b", x: 9, y: 9)])
        // Unsealed mutation still in WAL.
        XCTAssertGreaterThan(
            try Data(contentsOf: DatabaseLayout(root: root).walLog(collection: "docs")).count,
            0
        )
        try await db.close()

        let reopened = try await Database.open(path: root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 2)
        let got = await col.get(ids: ["b"], withVector: true)
        XCTAssertEqual(got[0].vector, [9, 9])
        try await reopened.checkpoint()
        try await reopened.close()

        // After second seal, WAL empty again; both points in latest segment.
        XCTAssertEqual(
            try Data(contentsOf: DatabaseLayout(root: root).walLog(collection: "docs")).count,
            0
        )
        let again = try await Database.open(path: root)
        let againCol = try await again.collection(name: "docs")
        let n = await againCol.count()
        XCTAssertEqual(n, 2)
        try await again.close()
    }

    func testDeleteThenSealOmitsIdFromSegment() async throws {
        let root = try tempRoot("del-seal")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([point("keep"), point("drop", x: 2)])
        try await db.collection(name: "docs").delete(ids: ["drop"])
        try await db.checkpoint()
        try await db.close()

        let layout = DatabaseLayout(root: root)
        let manifest = try JSONFileStore.read(
            ManifestDocument.self,
            from: layout.manifest(collection: "docs")
        )
        let segmentId = try XCTUnwrap(manifest.segmentIds.first)
        let ids = try IdSegmentFile.read(
            from: layout.idsBin(collection: "docs", segmentId: segmentId)
        )
        XCTAssertEqual(ids.ids, ["keep"])

        let reopened = try await Database.open(path: root)
        let reopenedCol = try await reopened.collection(name: "docs")
        let count = await reopenedCol.count()
        XCTAssertEqual(count, 1)
        try await reopened.close()
    }

    func testEphemeralCheckpointDoesNotSeal() async throws {
        let db = try await Database.open(
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([point("a")])
        try await db.checkpoint()
        try await db.close()
    }

    func testEmptyCheckpointDoesNotCreateSegment() async throws {
        let root = try tempRoot("empty-cp")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .balanced, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.checkpoint()
        XCTAssertFalse(
            JSONFileStore.exists(DatabaseLayout(root: root).manifest(collection: "docs"))
        )
        try await db.close()
    }

    func testSealedSegmentIORoundTrip() throws {
        let dir = try tempRoot("seg-io")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = DatabaseLayout(root: dir)
        let name = "docs"
        let segmentId: UInt64 = 1
        let rows = [
            SealedSegmentIO.Row(id: "a", vector: [1, 2], payload: ["x": .int(1)]),
            SealedSegmentIO.Row(id: "b", vector: [3, 4], payload: [:]),
        ]
        _ = try SealedSegmentIO.writeSegment(
            segmentId: segmentId,
            dimension: 2,
            index: .flat,
            rows: rows,
            segmentDirectory: layout.segmentDirectory(collection: name, segmentId: segmentId),
            vectorsURL: layout.vectorsBin(collection: name, segmentId: segmentId),
            idsURL: layout.idsBin(collection: name, segmentId: segmentId),
            payloadURL: layout.payloadBin(collection: name, segmentId: segmentId),
            metaURL: layout.segmentMeta(collection: name, segmentId: segmentId)
        )
        let loaded = try SealedSegmentIO.loadSegment(
            segmentId: segmentId,
            expectedDimension: 2,
            vectorsURL: layout.vectorsBin(collection: name, segmentId: segmentId),
            idsURL: layout.idsBin(collection: name, segmentId: segmentId),
            payloadURL: layout.payloadBin(collection: name, segmentId: segmentId),
            metaURL: layout.segmentMeta(collection: name, segmentId: segmentId)
        )
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "a")
        XCTAssertEqual(loaded[0].vector, [1, 2])
        XCTAssertEqual(loaded[1].vector, [3, 4])
    }
}
