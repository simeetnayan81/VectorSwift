import XCTest
import Foundation
import VectorSwift
import VectorSwiftCore
import VectorSwiftStorage

/// Unit and policy tests for S14 durability levels (fsync policy).
///
/// Fsync-count assertions construct `Collection` + `WriteAheadLog` with
/// `WALIOStats` directly. Database-level survival remains in WALDurabilityTests.
final class DurabilityPolicyTests: XCTestCase {

    // MARK: - Helpers

    private func tempDir(_ label: String = "dur") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCollection(
        durability: DurabilityLevel,
        stats: WALIOStats? = nil,
        policy: BalancedDurabilityPolicy = .default,
        dimension: Int = 2,
        name: String = "docs"
    ) throws -> (Collection, URL, WALIOStats) {
        let dir = try tempDir()
        let observed = stats ?? WALIOStats()
        let wal = WriteAheadLog(
            url: dir.appendingPathComponent("wal.log"),
            stats: observed
        )
        let col = try Collection(
            config: CollectionConfig(name: name, dimension: dimension, metric: .l2),
            durability: durability,
            wal: wal,
            balancedPolicy: policy
        )
        return (col, dir, observed)
    }

    private func point(_ id: String, x: Float = 1, y: Float = 0) -> Point {
        Point(id: id, vector: [x, y])
    }

    // MARK: - WALIOStats / WriteAheadLog

    func testAppendReturnsFrameByteCount() throws {
        let dir = try tempDir("bytes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wal = WriteAheadLog(url: dir.appendingPathComponent("wal.log"))

        let record = WALRecord.upsert(id: "a", vector: [1, 2], payload: ["k": .string("v")])
        let encoded = try WALCodec.encodeFrame(record)
        let written = try wal.append(record, sync: false)
        XCTAssertEqual(written, encoded.count)
        XCTAssertEqual(try Data(contentsOf: wal.url).count, encoded.count)

        let batch: [WALRecord] = [
            .delete(ids: ["a"]),
            .checkpointMark,
        ]
        var expected = 0
        for r in batch { expected += try WALCodec.encodeFrame(r).count }
        let batchBytes = try wal.append(contentsOf: batch, sync: false)
        XCTAssertEqual(batchBytes, expected)
        XCTAssertEqual(try Data(contentsOf: wal.url).count, encoded.count + expected)
    }

    func testSynchronizeCountIncrementsOnlyWhenSyncTrue() throws {
        let dir = try tempDir("stats")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = WALIOStats()
        let wal = WriteAheadLog(url: dir.appendingPathComponent("wal.log"), stats: stats)

        try wal.append(.checkpointMark, sync: false)
        XCTAssertEqual(stats.synchronizeCount, 0)

        try wal.append(.checkpointMark, sync: true)
        XCTAssertEqual(stats.synchronizeCount, 1)

        try wal.append(contentsOf: [
            .upsert(id: "a", vector: [1], payload: [:]),
            .delete(ids: ["a"]),
        ], sync: true)
        XCTAssertEqual(stats.synchronizeCount, 2, "batch append fsyncs once")

        try wal.synchronize()
        XCTAssertEqual(stats.synchronizeCount, 3)
    }

    func testTruncateIncrementsSynchronizeCount() throws {
        let dir = try tempDir("trunc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = WALIOStats()
        let wal = WriteAheadLog(url: dir.appendingPathComponent("wal.log"), stats: stats)

        try wal.append(.upsert(id: "a", vector: [1], payload: [:]), sync: false)
        let goodSize = try Data(contentsOf: wal.url).count
        let handle = try FileHandle(forWritingTo: wal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01, 0x00]))
        try handle.close()

        _ = try wal.readAllValidRecords(truncateIncompleteTail: true)
        XCTAssertEqual(try Data(contentsOf: wal.url).count, goodSize)
        XCTAssertEqual(stats.synchronizeCount, 1, "truncate path fsyncs")
    }

    // MARK: - Strict

    func testStrictUpsertFsyncsOncePerBatch() async throws {
        let (col, dir, stats) = try makeCollection(durability: .strict)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Snapshot after init (replay may have fsynced a truncate; empty WAL → 0).
        let baseline = stats.synchronizeCount

        try await col.upsert([point("a"), point("b", x: 0, y: 1)])
        XCTAssertEqual(stats.synchronizeCount, baseline + 1)

        try await col.upsert([point("c")])
        XCTAssertEqual(stats.synchronizeCount, baseline + 2)

        try await col.delete(ids: ["a"])
        XCTAssertEqual(stats.synchronizeCount, baseline + 3)
    }

    func testStrictEmptyBatchDoesNotFsync() async throws {
        let (col, dir, stats) = try makeCollection(durability: .strict)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount
        try await col.upsert([])
        try await col.delete(ids: [])
        XCTAssertEqual(stats.synchronizeCount, baseline)
    }

    // MARK: - Balanced thresholds

    func testBalancedNoFsyncBelowRecordThreshold() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 10,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000 // 60s — won't fire in test
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        for i in 0..<9 {
            try await col.upsert([point("p\(i)", x: Float(i))])
        }
        XCTAssertEqual(stats.synchronizeCount, baseline)
        let _count = await col.count()
        XCTAssertEqual(_count, 9)
    }

    func testBalancedFsyncOnRecordThreshold() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 3,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("a")])
        try await col.upsert([point("b")])
        XCTAssertEqual(stats.synchronizeCount, baseline)

        try await col.upsert([point("c")])
        XCTAssertEqual(stats.synchronizeCount, baseline + 1, "3rd record trips N threshold")

        // Counters reset; next two should not sync.
        try await col.upsert([point("d")])
        try await col.upsert([point("e")])
        XCTAssertEqual(stats.synchronizeCount, baseline + 1)
        try await col.upsert([point("f")])
        XCTAssertEqual(stats.synchronizeCount, baseline + 2)
    }

    func testBalancedBatchCountsAllRecordsTowardThreshold() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 5,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        // One API call with 5 points → one pending bump of 5 → threshold trip → 1 fsync.
        let points = (0..<5).map { point("b\($0)", x: Float($0)) }
        try await col.upsert(points)
        XCTAssertEqual(stats.synchronizeCount, baseline + 1)
        let _count = await col.count()
        XCTAssertEqual(_count, 5)
    }

    func testBalancedFsyncOnByteThreshold() async throws {
        // Tiny byte threshold so a single upsert frame exceeds B.
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 1_000_000,
            syncEveryBytes: 1,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("big")])
        XCTAssertEqual(stats.synchronizeCount, baseline + 1)
    }

    func testBalancedDeferredTimerFsync() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 1_000_000,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 50_000_000 // 50 ms
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("timed")])
        XCTAssertEqual(stats.synchronizeCount, baseline)

        // Wait well past the dirty-window deadline.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stats.synchronizeCount, baseline + 1, "coalesced timer should fsync")
        let _count = await col.count()
        XCTAssertEqual(_count, 1)
    }

    func testBalancedThresholdCancelsPendingTimerWithoutDoubleFsync() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 2,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 200_000_000 // 200 ms
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("a")]) // arms timer
        try await col.upsert([point("b")]) // trips N=2, fsync + cancel timer
        XCTAssertEqual(stats.synchronizeCount, baseline + 1)

        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(
            stats.synchronizeCount,
            baseline + 1,
            "cancelled dirty-window timer must not fsync again"
        )
    }

    // MARK: - Relaxed

    func testRelaxedHotPathNeverFsyncs() async throws {
        let (col, dir, stats) = try makeCollection(durability: .relaxed)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        for i in 0..<20 {
            try await col.upsert([point("r\(i)", x: Float(i))])
        }
        try await col.delete(ids: ["r0", "r1"])
        XCTAssertEqual(stats.synchronizeCount, baseline)
        let _count = await col.count()
        XCTAssertEqual(_count, 18)
    }

    func testRelaxedCheckpointFsyncs() async throws {
        let (col, dir, stats) = try makeCollection(durability: .relaxed)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("a")])
        XCTAssertEqual(stats.synchronizeCount, baseline)

        try await col.checkpoint()
        XCTAssertEqual(stats.synchronizeCount, baseline + 1, "checkpoint is durability barrier")
    }

    // MARK: - Checkpoint / close barriers (all levels)

    func testCheckpointFsyncsForAllLevels() async throws {
        for level in DurabilityLevel.allCases {
            let policy = BalancedDurabilityPolicy(
                syncEveryRecords: 1_000_000,
                syncEveryBytes: 1_000_000_000,
                syncIntervalNanoseconds: 60_000_000_000
            )
            let (col, dir, stats) = try makeCollection(durability: level, policy: policy)
            defer { try? FileManager.default.removeItem(at: dir) }

            try await col.upsert([point("x")])
            let before = stats.synchronizeCount
            try await col.checkpoint()
            XCTAssertGreaterThan(
                stats.synchronizeCount,
                before,
                "checkpoint must fsync for \(level)"
            )
        }
    }

    func testPrepareForCloseSyncsWAL() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 1_000_000,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("a")])
        XCTAssertEqual(stats.synchronizeCount, baseline)

        try await col.prepareForClose(syncWAL: true)
        XCTAssertEqual(stats.synchronizeCount, baseline + 1)

        // Mutations rejected after close prep.
        do {
            try await col.upsert([point("b")])
            XCTFail("expected closed")
        } catch VectorSwiftError.closed {
            // expected
        }
    }

    func testPrepareForCloseWithoutSyncDoesNotFsync() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 1_000_000,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseline = stats.synchronizeCount

        try await col.upsert([point("a")])
        try await col.prepareForClose(syncWAL: false)
        XCTAssertEqual(stats.synchronizeCount, baseline)

        do {
            try await col.upsert([point("b")])
            XCTFail("expected closed")
        } catch VectorSwiftError.closed {
            // expected
        }
    }

    // MARK: - Sticky sync errors

    func testStickyBlocksMutationsUntilCheckpointRecovers() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 2,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await col.upsert([point("a")])
        // Next upsert trips threshold; force fsync failure.
        stats.forceNextSynchronizeError = .io("injected fsync failure")
        do {
            try await col.upsert([point("b")])
            XCTFail("expected sticky/io error")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .io("injected fsync failure"))
        }

        // Sticky: further mutations fail without clearing.
        do {
            try await col.upsert([point("c")])
            XCTFail("expected sticky")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .io("injected fsync failure"))
        }

        // Reads still work for points applied before the failed barrier.
        // "b" was not applied (fsync failed before memory apply).
        let count = await col.count()
        XCTAssertEqual(count, 1)
        let got = await col.get(ids: ["a", "b"])
        XCTAssertEqual(got.map(\.id), ["a"])

        // Empty batches ignore sticky.
        try await col.upsert([])

        // Checkpoint retries fsync and clears sticky on success.
        try await col.checkpoint()
        try await col.upsert([point("c")])
        let _count = await col.count()
        XCTAssertEqual(_count, 2)
    }

    func testStickyFromDeferredTimerBlocksMutations() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 1_000_000,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 30_000_000 // 30 ms
        )
        let (col, dir, stats) = try makeCollection(durability: .balanced, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await col.upsert([point("a")])
        stats.forceNextSynchronizeError = .io("timer fsync fail")
        try await Task.sleep(nanoseconds: 150_000_000)

        do {
            try await col.upsert([point("b")])
            XCTFail("expected sticky after deferred fsync failure")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .io("timer fsync fail"))
        }

        // Recover via prepareForClose then — use checkpoint with forced error cleared.
        try await col.checkpoint()
        try await col.upsert([point("b")])
        let _count = await col.count()
        XCTAssertEqual(_count, 2)
    }

    func testStrictFsyncFailureDoesNotApplyMemory() async throws {
        let (col, dir, stats) = try makeCollection(durability: .strict)
        defer { try? FileManager.default.removeItem(at: dir) }

        stats.forceNextSynchronizeError = .io("strict fail")
        do {
            try await col.upsert([point("lost")])
            XCTFail("expected error")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .io("strict fail"))
        }
        let countAfterFail = await col.count()
        XCTAssertEqual(countAfterFail, 0)

        // Sticky blocks until barrier succeeds.
        do {
            try await col.upsert([point("next")])
            XCTFail("expected sticky")
        } catch VectorSwiftError.io {
            // ok
        }
        try await col.checkpoint()
        try await col.upsert([point("ok")])
        let countAfterRecover = await col.count()
        XCTAssertEqual(countAfterRecover, 1)
    }

    // MARK: - Database close / drop integration

    func testDatabaseCloseFsyncsBalancedWAL() async throws {
        let root = try tempDir("db-close")
        defer { try? FileManager.default.removeItem(at: root) }

        // Reopen survival of un-checkpointed balanced writes proves close flushes.
        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .balanced, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([point("persist")])
        try await db.close()

        let reopened = try await Database.open(path: root)
        let reopenedCol = try await reopened.collection(name: "docs")
        let got = await reopenedCol.get(ids: ["persist"], withVector: true)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].vector, [1, 0])
        try await reopened.close()
    }

    func testDatabaseCloseFsyncsRelaxedWAL() async throws {
        let root = try tempDir("db-close-relaxed")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .relaxed, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([
            point("a"),
            point("b", x: 0, y: 1),
        ])
        try await db.close()

        let reopened = try await Database.open(path: root)
        let reopenedCol = try await reopened.collection(name: "docs")
        let count = await reopenedCol.count()
        XCTAssertEqual(count, 2)
        try await reopened.close()
    }

    func testDropCollectionStopsMutationsAndRemovesDir() async throws {
        let root = try tempDir("db-drop")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .balanced, compute: .cpu)
        )
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([point("a")])
        try await db.dropCollection(name: "docs")

        let layout = DatabaseLayout(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.collectionDirectory(name: "docs").path))

        do {
            try await col.upsert([point("b")])
            XCTFail("expected closed after drop")
        } catch VectorSwiftError.closed {
            // expected
        }

        try await db.close()
    }

    func testEphemeralHasNoWALFsyncSemantics() async throws {
        let db = try await Database.open(config: DatabaseConfig(durability: .strict, compute: .cpu))
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.collection(name: "docs").upsert([point("a")])
        try await db.checkpoint()
        try await db.close()
    }

    // MARK: - Defaults

    func testBalancedDefaultsMatchDesign() {
        XCTAssertEqual(BalancedDurabilityDefaults.syncEveryRecords, 64)
        XCTAssertEqual(BalancedDurabilityDefaults.syncEveryBytes, 256 * 1024)
        XCTAssertEqual(BalancedDurabilityDefaults.syncIntervalNanoseconds, 100_000_000)
        XCTAssertEqual(BalancedDurabilityPolicy.default.syncEveryRecords, 64)
    }

    func testDurabilityLevelCodable() throws {
        for level in DurabilityLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(DurabilityLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    // MARK: - Write-before-memory invariant (WAL file non-empty after balanced upsert)

    func testBalancedWritesWALBeforeAck() async throws {
        let policy = BalancedDurabilityPolicy(
            syncEveryRecords: 1_000_000,
            syncEveryBytes: 1_000_000_000,
            syncIntervalNanoseconds: 60_000_000_000
        )
        let dir = try tempDir("wal-before-ack")
        defer { try? FileManager.default.removeItem(at: dir) }
        let walURL = dir.appendingPathComponent("wal.log")
        let wal = WriteAheadLog(url: walURL)
        let col = try Collection(
            config: CollectionConfig(name: "docs", dimension: 2, metric: .l2),
            durability: .balanced,
            wal: wal,
            balancedPolicy: policy
        )
        try await col.upsert([point("a")])
        let size = try Data(contentsOf: walURL).count
        XCTAssertGreaterThan(size, 0, "WAL must contain frames after balanced upsert ack")
        let records = try wal.readAllValidRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testRelaxedWritesWALBeforeAck() async throws {
        let dir = try tempDir("relaxed-wal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let walURL = dir.appendingPathComponent("wal.log")
        let col = try Collection(
            config: CollectionConfig(name: "docs", dimension: 2, metric: .l2),
            durability: .relaxed,
            wal: WriteAheadLog(url: walURL)
        )
        try await col.upsert([point("a")])
        XCTAssertGreaterThan(try Data(contentsOf: walURL).count, 0)
    }
}
