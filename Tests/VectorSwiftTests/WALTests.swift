import XCTest
import Foundation
import VectorSwiftCore
import VectorSwiftStorage

final class WALTests: XCTestCase {

    private func tempWAL(_ label: String = "wal") throws -> WriteAheadLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WriteAheadLog(url: dir.appendingPathComponent("wal.log", isDirectory: false))
    }

    private func assertCorrupted(
        _ expression: @autoclosure () throws -> some Any,
        reasonContains: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case VectorSwiftError.corrupted(_, let reason) = error else {
                return XCTFail("expected corrupted, got \(error)", file: file, line: line)
            }
            for needle in reasonContains {
                XCTAssertTrue(
                    reason.localizedCaseInsensitiveContains(needle),
                    "reason '\(reason)' should contain '\(needle)'",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - Encode / decode round-trip

    func testUpsertRoundTripAllPayloadTypes() throws {
        let payload: [String: PayloadValue] = [
            "n": .null,
            "b": .bool(true),
            "i": .int(-42),
            "d": .double(3.5),
            "s": .string("hello"),
            "ss": .strings(["a", "b"]),
        ]
        let record = WALRecord.upsert(
            id: "point-1",
            vector: [1, -2.5, 0, Float.infinity],
            payload: payload
        )
        let frame = try WALCodec.encodeFrame(record)
        var offset = 0
        guard case .record(let decoded, let next) = try WALCodec.readFrame(from: frame, at: 0) else {
            return XCTFail("expected complete record")
        }
        offset = next
        XCTAssertEqual(offset, frame.count)
        XCTAssertEqual(decoded, record)
    }

    func testDeleteRoundTripMultiId() throws {
        let record = WALRecord.delete(ids: ["a", "b", "unicode-点"])
        let frame = try WALCodec.encodeFrame(record)
        guard case .record(let decoded, let next) = try WALCodec.readFrame(from: frame, at: 0) else {
            return XCTFail("expected complete record")
        }
        XCTAssertEqual(next, frame.count)
        XCTAssertEqual(decoded, record)
    }

    func testCheckpointAndSealRoundTrip() throws {
        for record in [WALRecord.checkpointMark, WALRecord.sealSegment(segmentId: 99)] {
            let frame = try WALCodec.encodeFrame(record)
            guard case .record(let decoded, let next) = try WALCodec.readFrame(from: frame, at: 0) else {
                return XCTFail("expected complete record for \(record)")
            }
            XCTAssertEqual(next, frame.count)
            XCTAssertEqual(decoded, record)
        }
    }

    func testMaxLengthPointIDRoundTrip() throws {
        let id = String(repeating: "x", count: VectorSwiftLimits.maxPointIDUTF8ByteCount)
        let record = WALRecord.upsert(id: id, vector: [1, 2], payload: [:])
        let frame = try WALCodec.encodeFrame(record)
        guard case .record(let decoded, _) = try WALCodec.readFrame(from: frame, at: 0) else {
            return XCTFail("expected complete record")
        }
        XCTAssertEqual(decoded, record)
    }

    // MARK: - Multi-record file

    func testAppendAndReadMultipleRecords() throws {
        let wal = try tempWAL()
        defer { try? FileManager.default.removeItem(at: wal.url.deletingLastPathComponent()) }

        let records: [WALRecord] = [
            .upsert(id: "a", vector: [1, 0], payload: ["k": .string("v")]),
            .upsert(id: "b", vector: [0, 1], payload: [:]),
            .delete(ids: ["a"]),
            .checkpointMark,
        ]
        try wal.append(contentsOf: records, sync: false)
        let read = try wal.readAllValidRecords()
        XCTAssertEqual(read, records)
    }

    func testEmptyAndMissingWAL() throws {
        let wal = try tempWAL("empty")
        defer { try? FileManager.default.removeItem(at: wal.url.deletingLastPathComponent()) }

        XCTAssertEqual(try wal.readAllValidRecords(), [])

        // Create zero-byte file
        FileManager.default.createFile(atPath: wal.url.path, contents: Data())
        XCTAssertEqual(try wal.readAllValidRecords(), [])
    }

    // MARK: - Corruption

    func testCRCFailureIsCorrupted() throws {
        let record = WALRecord.upsert(id: "a", vector: [1, 2, 3], payload: [:])
        var frame = try WALCodec.encodeFrame(record)
        // Flip a byte inside type+payload (after len, before crc).
        let flipIndex = 5
        frame[flipIndex] ^= 0xFF
        assertCorrupted(try WALCodec.readFrame(from: frame, at: 0), reasonContains: ["CRC"])
    }

    func testUnknownTypeIsCorrupted() throws {
        // Build a frame with type 99 manually.
        var body = Data([99, 0x01, 0x02])
        let crc = CRC32.checksum(body)
        BinaryIO.appendUInt32(crc, to: &body) // wrong — need separate
        // Rebuild properly:
        body = Data([99, 0x01, 0x02])
        let checksum = CRC32.checksum(body)
        var frame = Data()
        BinaryIO.appendUInt32(UInt32(body.count + 4), to: &frame)
        frame.append(body)
        BinaryIO.appendUInt32(checksum, to: &frame)

        assertCorrupted(try WALCodec.readFrame(from: frame, at: 0), reasonContains: ["type"])
    }

    // MARK: - Torn tail

    func testIncompleteTailTruncated() throws {
        let wal = try tempWAL("torn")
        defer { try? FileManager.default.removeItem(at: wal.url.deletingLastPathComponent()) }

        let good: [WALRecord] = [
            .upsert(id: "keep", vector: [9, 8], payload: [:]),
            .delete(ids: ["gone"]),
        ]
        try wal.append(contentsOf: good, sync: false)

        let goodSize = try Data(contentsOf: wal.url).count

        // Append garbage / partial frame (len claims more than available).
        var partial = Data()
        BinaryIO.appendUInt32(100, to: &partial) // claims 100 bytes after len
        partial.append(contentsOf: [1, 2, 3, 4]) // only 4 of them
        let handle = try FileHandle(forWritingTo: wal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: partial)
        try handle.close()

        let read = try wal.readAllValidRecords(truncateIncompleteTail: true)
        XCTAssertEqual(read, good)

        let after = try Data(contentsOf: wal.url)
        XCTAssertEqual(after.count, goodSize, "file should be truncated to last good offset")
    }

    func testPartialLenFieldAtEOFTruncated() throws {
        let wal = try tempWAL("partial-len")
        defer { try? FileManager.default.removeItem(at: wal.url.deletingLastPathComponent()) }

        try wal.append(.upsert(id: "a", vector: [1], payload: [:]), sync: false)
        let goodSize = try Data(contentsOf: wal.url).count

        // Only 2 of 4 len bytes
        let handle = try FileHandle(forWritingTo: wal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01, 0x00]))
        try handle.close()

        let read = try wal.readAllValidRecords()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(try Data(contentsOf: wal.url).count, goodSize)
    }

    func testLenTooSmallIsCorruptedNotTruncated() throws {
        var frame = Data()
        BinaryIO.appendUInt32(3, to: &frame) // too small (< 5)
        frame.append(contentsOf: [1, 2, 3])
        assertCorrupted(
            try WALCodec.readFrame(from: frame, at: 0),
            reasonContains: ["too small"]
        )
    }

    // MARK: - Layout helpers

    func testLayoutWALPaths() {
        let root = URL(fileURLWithPath: "/tmp/db", isDirectory: true)
        let layout = DatabaseLayout(root: root)
        XCTAssertTrue(layout.walDirectory(collection: "docs").path.hasSuffix("collections/docs/wal"))
        XCTAssertTrue(layout.walLog(collection: "docs").path.hasSuffix("collections/docs/wal/wal.log"))
    }
}
