import XCTest
import Foundation
import VectorSwiftStorage

final class StorageRecoveryTests: XCTestCase {

    private func tempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - replayStartIndex

    func testReplayStartIndexEmpty() {
        XCTAssertEqual(
            StorageRecovery.replayStartIndex(records: [], publishedSegmentIds: [1]),
            0
        )
    }

    func testReplayStartIndexNoSealsReplaysEverything() {
        let records: [WALRecord] = [
            .upsert(id: "a", vector: [1], payload: [:]),
            .delete(ids: ["b"]),
            .checkpointMark,
        ]
        XCTAssertEqual(
            StorageRecovery.replayStartIndex(records: records, publishedSegmentIds: [1]),
            0
        )
    }

    func testReplayStartIndexUnpublishedSealDoesNotAdvance() {
        let records: [WALRecord] = [
            .upsert(id: "a", vector: [1], payload: [:]),
            .sealSegmentV2(
                WALSealSegmentV2Payload(
                    segmentId: 9,
                    rowCount: 1,
                    vectorsCrc32: 1,
                    idsCrc32: 2,
                    payloadsCrc32: 3
                )
            ),
        ]
        XCTAssertEqual(
            StorageRecovery.replayStartIndex(records: records, publishedSegmentIds: [1]),
            0
        )
    }

    func testReplayStartIndexSkipsThroughLastPublishedSeal() {
        let seal1 = WALSealSegmentV2Payload(
            segmentId: 1,
            rowCount: 1,
            vectorsCrc32: 1,
            idsCrc32: 2,
            payloadsCrc32: 3
        )
        let seal2 = WALSealSegmentV2Payload(
            segmentId: 2,
            rowCount: 1,
            vectorsCrc32: 4,
            idsCrc32: 5,
            payloadsCrc32: 6
        )
        let records: [WALRecord] = [
            .upsert(id: "a", vector: [1], payload: [:]),
            .sealSegmentV2(seal1),
            .upsert(id: "b", vector: [2], payload: [:]),
            .sealSegmentV2(seal2),
            .upsert(id: "c", vector: [3], payload: [:]),
        ]
        XCTAssertEqual(
            StorageRecovery.replayStartIndex(records: records, publishedSegmentIds: [1, 2]),
            4
        )
        XCTAssertEqual(
            StorageRecovery.replayStartIndex(records: records, publishedSegmentIds: [1]),
            2
        )
    }

    func testReplayStartIndexAcceptsLegacySeal() {
        let records: [WALRecord] = [
            .upsert(id: "a", vector: [1], payload: [:]),
            .sealSegment(segmentId: 3),
            .upsert(id: "b", vector: [2], payload: [:]),
        ]
        XCTAssertEqual(
            StorageRecovery.replayStartIndex(records: records, publishedSegmentIds: [3]),
            2
        )
    }

    // MARK: - nextSegmentId repair

    func testRepairedNextSegmentIdUsesManifestMax() {
        XCTAssertEqual(
            StorageRecovery.repairedNextSegmentId(persisted: 1, publishedSegmentIds: [1]),
            2
        )
        XCTAssertEqual(
            StorageRecovery.repairedNextSegmentId(persisted: 5, publishedSegmentIds: [1, 2]),
            5
        )
        XCTAssertEqual(
            StorageRecovery.repairedNextSegmentId(persisted: 1, publishedSegmentIds: []),
            1
        )
    }

    // MARK: - orphan + tmp reclaim

    func testRemoveUnlistedSegmentDirectories() throws {
        let root = try tempDir("orphan-dirs")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DatabaseLayout(root: root)
        let segs = layout.segmentsDirectory(collection: "docs")
        try FileManager.default.createDirectory(
            at: layout.segmentDirectory(collection: "docs", segmentId: 1),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.segmentDirectory(collection: "docs", segmentId: 2),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: segs.appendingPathComponent("scratch", isDirectory: true),
            withIntermediateDirectories: true
        )

        let removed = StorageRecovery.removeUnlistedSegmentDirectories(
            segmentsDirectory: segs,
            liveSegmentIds: [1]
        )
        XCTAssertEqual(removed, [2])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.segmentDirectory(collection: "docs", segmentId: 1).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.segmentDirectory(collection: "docs", segmentId: 2).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: segs.appendingPathComponent("scratch").path)
        )
    }

    func testRemoveLeftoverTemporaryFiles() throws {
        let root = try tempDir("tmp-gc")
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("MANIFEST.json")
        let junk = root.appendingPathComponent("MANIFEST.json.tmp")
        try Data("keep".utf8).write(to: keep)
        try Data("junk".utf8).write(to: junk)

        let removed = StorageRecovery.removeLeftoverTemporaryFiles(in: root)
        XCTAssertEqual(removed.map(\.lastPathComponent), ["MANIFEST.json.tmp"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
    }
}
