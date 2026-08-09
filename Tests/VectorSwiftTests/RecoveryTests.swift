import XCTest
import Foundation
import VectorSwift
import VectorSwiftCore
import VectorSwiftStorage

/// Crash-shaped recovery: plant on-disk state, then `Database.open`.
///
/// These tests do not kill the process. Each case writes the files a crash at that
/// step would have left behind.
final class RecoveryTests: XCTestCase {

    private func tempRoot(_ label: String = "recovery") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openStrict(_ root: URL) async throws -> Database {
        try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )
    }

    private func writePlantedSegment(
        layout: DatabaseLayout,
        collection: String,
        segmentId: UInt64,
        rows: [SealedSegmentIO.Row]
    ) throws -> SealedSegmentIO.WriteResult {
        try SealedSegmentIO.writeSegment(
            segmentId: segmentId,
            dimension: 2,
            index: .flat,
            rows: rows,
            tombstones: [],
            segmentDirectory: layout.segmentDirectory(collection: collection, segmentId: segmentId),
            vectorsURL: layout.vectorsBin(collection: collection, segmentId: segmentId),
            idsURL: layout.idsBin(collection: collection, segmentId: segmentId),
            payloadURL: layout.payloadBin(collection: collection, segmentId: segmentId),
            tombstonesURL: layout.tombstonesBin(collection: collection, segmentId: segmentId),
            metaURL: layout.segmentMeta(collection: collection, segmentId: segmentId)
        )
    }

    // MARK: - Happy strict restart

    func testStrictAckedUpsertSurvivesReopen() async throws {
        let root = try tempRoot("strict-ack")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [1, 0], payload: ["k": .string("v")])])
            try await db.close()
        }

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.first?.vector, [1, 0])
        XCTAssertEqual(got.first?.payload["k"], .string("v"))
        try await reopened.close()
    }

    // MARK: - Incomplete seal / orphans

    func testUnlistedSegmentDirectoryIsIgnoredAndRemoved() async throws {
        let root = try tempRoot("orphan-dir")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "keep", vector: [1, 0])])
            try await db.checkpoint()
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        _ = try writePlantedSegment(
            layout: layout,
            collection: "docs",
            segmentId: 99,
            rows: [SealedSegmentIO.Row(id: "ghost", vector: [9, 9], payload: [:])]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.segmentDirectory(collection: "docs", segmentId: 99).path
            )
        )

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let ghost = await col.get(ids: ["ghost"], withVector: false)
        XCTAssertTrue(ghost.isEmpty)
        let keep = await col.get(ids: ["keep"], withVector: true)
        XCTAssertEqual(keep.first?.vector, [1, 0])
        try await reopened.close()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.segmentDirectory(collection: "docs", segmentId: 99).path
            )
        )
    }

    func testIncompleteSealWithoutManifestReplaysWAL() async throws {
        let root = try tempRoot("seal-no-manifest")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [1, 2])])
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        let orphan = layout.segmentDirectory(collection: "docs", segmentId: 1)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("partial-vectors".utf8).write(to: layout.vectorsBin(collection: "docs", segmentId: 1))

        let wal = WriteAheadLog(url: layout.walLog(collection: "docs"))
        try wal.append(
            .sealSegmentV2(
                WALSealSegmentV2Payload(
                    segmentId: 1,
                    rowCount: 1,
                    vectorsCrc32: 0,
                    idsCrc32: 0,
                    payloadsCrc32: 0
                )
            ),
            sync: true
        )

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.first?.vector, [1, 2])
        try await reopened.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(JSONFileStore.exists(layout.manifest(collection: "docs")))
    }

    func testUnpublishedSealRecordIsNoOp() async throws {
        let root = try tempRoot("unpublished-seal")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [3, 4])])
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        let wal = WriteAheadLog(url: layout.walLog(collection: "docs"))
        try wal.append(
            .sealSegmentV2(
                WALSealSegmentV2Payload(
                    segmentId: 1,
                    rowCount: 1,
                    vectorsCrc32: 1,
                    idsCrc32: 1,
                    payloadsCrc32: 1
                )
            ),
            sync: true
        )

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.first?.vector, [3, 4])
        try await reopened.close()
    }

    // MARK: - Crash after MANIFEST publish

    func testPublishedManifestWithUnreclaimedWALReplaysOnlyAfterSeal() async throws {
        let root = try tempRoot("manifest-then-crash")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([
                Point(id: "a", vector: [1, 0]),
                Point(id: "b", vector: [0, 1]),
            ])
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        let written = try writePlantedSegment(
            layout: layout,
            collection: "docs",
            segmentId: 1,
            rows: [
                SealedSegmentIO.Row(id: "a", vector: [1, 0], payload: [:]),
                SealedSegmentIO.Row(id: "b", vector: [0, 1], payload: [:]),
            ]
        )
        try JSONFileStore.writeAtomic(
            ManifestDocument(generation: 1, segmentIds: [1], walEpoch: 1),
            to: layout.manifest(collection: "docs")
        )
        let wal = WriteAheadLog(url: layout.walLog(collection: "docs"))
        try wal.append(
            .sealSegmentV2(
                WALSealSegmentV2Payload(
                    segmentId: written.segmentId,
                    rowCount: written.rowCount,
                    vectorsCrc32: written.vectorsCrc32,
                    idsCrc32: written.idsCrc32,
                    payloadsCrc32: written.payloadsCrc32
                )
            ),
            sync: true
        )

        // COLL_META still says nextSegmentId == 1 (crash before meta persist).
        let metaBefore = try JSONFileStore.read(
            CollectionMetaDocument.self,
            from: layout.collectionMeta(name: "docs")
        )
        XCTAssertEqual(metaBefore.nextSegmentId, 1)

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 2, "sealed prefix must not duplicate into mutable")
        let gotA = await col.get(ids: ["a"], withVector: true)
        let gotB = await col.get(ids: ["b"], withVector: true)
        XCTAssertEqual(gotA.first?.vector, [1, 0])
        XCTAssertEqual(gotB.first?.vector, [0, 1])

        try await col.upsert([Point(id: "c", vector: [2, 2])])
        try await reopened.checkpoint()
        try await reopened.close()

        let manifest = try JSONFileStore.read(
            ManifestDocument.self,
            from: layout.manifest(collection: "docs")
        )
        XCTAssertEqual(manifest.segmentIds, [1, 2], "repaired next id must not overwrite segment 1")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.segmentDirectory(collection: "docs", segmentId: 1).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.segmentDirectory(collection: "docs", segmentId: 2).path
            )
        )

        let again = try await openStrict(root)
        let docs = try await again.collection(name: "docs")
        let againCount = await docs.count()
        XCTAssertEqual(againCount, 3)
        let ids = await docs.get(ids: ["a", "b", "c"], withVector: false)
        XCTAssertEqual(Set(ids.map(\.id)), ["a", "b", "c"])
        try await again.close()
    }

    func testMissingWALAfterSealLoadsFromSegments() async throws {
        let root = try tempRoot("missing-wal")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [5, 6])])
            try await db.checkpoint()
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        try FileManager.default.removeItem(at: layout.walLog(collection: "docs"))

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.first?.vector, [5, 6])
        try await reopened.close()
    }

    // MARK: - Leftover tmp + checksum

    func testLeftoverManifestTmpIgnoredAndRemoved() async throws {
        let root = try tempRoot("manifest-tmp")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [1, 1])])
            try await db.checkpoint()
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        let tmp = layout.manifest(collection: "docs").appendingPathExtension("tmp")
        try Data("{ not-the-manifest".utf8).write(to: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let reopened = try await openStrict(root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let got = await col.get(ids: ["a"], withVector: true)
        XCTAssertEqual(got.first?.vector, [1, 1])
        try await reopened.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertTrue(JSONFileStore.exists(layout.manifest(collection: "docs")))
    }

    func testCorruptListedSegmentThrowsOnOpen() async throws {
        let root = try tempRoot("crc-listed")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await openStrict(root)
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [1, 0])])
            try await db.checkpoint()
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        let vectorsURL = layout.vectorsBin(collection: "docs", segmentId: 1)
        var data = try Data(contentsOf: vectorsURL)
        data[data.count - 1] ^= 0xFF
        try data.write(to: vectorsURL)

        do {
            _ = try await openStrict(root)
            XCTFail("expected corrupted")
        } catch let error as VectorSwiftError {
            guard case .corrupted = error else {
                return XCTFail("expected corrupted, got \(error)")
            }
        }
    }

    /// Relaxed acked writes are visible after a clean process close (`close` fsyncs).
    /// Power-loss before that fsync is a documented loss window, not simulated here.
    func testRelaxedCleanCloseSurvivesReopen() async throws {
        let root = try tempRoot("relaxed-close")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await Database.open(
                path: root,
                config: DatabaseConfig(durability: .relaxed, compute: .cpu)
            )
            try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
            let col = try await db.collection(name: "docs")
            try await col.upsert([Point(id: "a", vector: [8, 1])])
            try await db.close()
        }

        let reopened = try await Database.open(path: root)
        let col = try await reopened.collection(name: "docs")
        let count = await col.count()
        XCTAssertEqual(count, 1)
        try await reopened.close()
    }
}
