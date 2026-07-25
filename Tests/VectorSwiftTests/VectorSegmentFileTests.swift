import XCTest
import VectorSwiftCore
import VectorSwiftStorage

final class VectorSegmentFileTests: XCTestCase {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-seg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - VECTORS.bin

    func testVectorsEmptyRoundTrip() throws {
        let file = try VectorSegmentFile.empty(dimension: 4)
        let data = try VectorSegmentFile.encode(file)
        let decoded = try VectorSegmentFile.decode(data)
        XCTAssertEqual(decoded.dimension, 4)
        XCTAssertEqual(decoded.count, 0)
        XCTAssertEqual(decoded.vectors, [])
        XCTAssertEqual(decoded.flags, 0)
    }

    func testVectorsSingleAndMultiRowRoundTrip() throws {
        let vectors: [Float] = [
            1, 2, 3,
            -0.5, 0, 4.25,
            0, 0, 0,
        ]
        let file = try VectorSegmentFile(dimension: 3, vectors: vectors, flags: 0)
        let decoded = try VectorSegmentFile.decode(try VectorSegmentFile.encode(file))
        XCTAssertEqual(decoded.dimension, 3)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.vectors, vectors)
    }

    func testVectorsWriteReadFile() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        let url = layout.vectorsBin(collection: "docs", segmentId: 1)
        let file = try VectorSegmentFile(dimension: 2, vectors: [1.0, 2.0, 3.0, 4.0])
        try VectorSegmentFile.write(file, to: url)

        let loaded = try VectorSegmentFile.read(from: url)
        XCTAssertEqual(loaded, file)
        XCTAssertTrue(url.path.hasSuffix("collections/docs/segments/1/VECTORS.bin"))
    }

    func testVectorsRejectsNonMultipleLength() {
        XCTAssertThrowsError(try VectorSegmentFile(dimension: 3, vectors: [1, 2])) { error in
            guard case VectorSwiftError.invalidArgument = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testVectorsFlipPayloadByteFailsCRC() throws {
        var data = try VectorSegmentFile.encode(
            try VectorSegmentFile(dimension: 2, vectors: [1, 2, 3, 4])
        )
        // Flip one byte in the float payload (after header, before CRC).
        let payloadIndex = VectorSegmentFile.headerByteCount
        data[payloadIndex] ^= 0xFF
        XCTAssertThrowsError(try VectorSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted(_, let reason) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(reason.contains("CRC"), reason)
        }
    }

    func testVectorsFlipCRCTrailerFails() throws {
        var data = try VectorSegmentFile.encode(
            try VectorSegmentFile(dimension: 2, vectors: [1, 2])
        )
        data[data.count - 1] ^= 0x01
        XCTAssertThrowsError(try VectorSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testVectorsBadMagic() throws {
        var data = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 2))
        // Overwrite magic with zeros.
        data[0] = 0
        data[1] = 0
        data[2] = 0
        data[3] = 0
        XCTAssertThrowsError(try VectorSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted(_, let reason) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(reason.contains("magic"), reason)
        }
    }

    func testVectorsTruncatedFile() {
        let short = Data([0x56, 0x56, 0x45, 0x43])
        XCTAssertThrowsError(try VectorSegmentFile.decode(short)) { error in
            guard case VectorSwiftError.corrupted = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testVectorsSizeMismatchDeclaredCount() throws {
        // Encode empty (count=0), then claim count=1 without payload → size mismatch path.
        var data = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 2))
        // count is at offset 12 (magic4 + version4 + dim4), u64 LE
        let countOffset = 12
        data[countOffset] = 1 // count = 1
        // Size still that of empty file → mismatch
        XCTAssertThrowsError(try VectorSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted(_, let reason) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(reason.contains("size") || reason.contains("CRC"), reason)
        }
    }

    // MARK: - IDS.bin

    func testIdsEmptyRoundTrip() throws {
        let file = IdSegmentFile.empty
        let decoded = try IdSegmentFile.decode(try IdSegmentFile.encode(file))
        XCTAssertEqual(decoded.ids, [])
    }

    func testIdsRoundTripUnicodeAndAscii() throws {
        let ids = ["a", "café", "向量", "with space", "emoji-😀"]
        let file = try IdSegmentFile(ids: ids)
        let decoded = try IdSegmentFile.decode(try IdSegmentFile.encode(file))
        XCTAssertEqual(decoded.ids, ids)
    }

    func testIdsMaxLengthRoundTrip() throws {
        let id = String(repeating: "x", count: VectorSwiftLimits.maxPointIDUTF8ByteCount)
        let file = try IdSegmentFile(ids: [id])
        let decoded = try IdSegmentFile.decode(try IdSegmentFile.encode(file))
        XCTAssertEqual(decoded.ids, [id])
    }

    func testIdsRejectsEmptyAndOversizeOnWrite() {
        XCTAssertThrowsError(try IdSegmentFile(ids: [""])) { error in
            guard case VectorSwiftError.invalidPointID = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        let tooLong = String(repeating: "y", count: VectorSwiftLimits.maxPointIDUTF8ByteCount + 1)
        XCTAssertThrowsError(try IdSegmentFile(ids: [tooLong])) { error in
            guard case VectorSwiftError.invalidPointID = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testIdsWriteReadFile() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        let url = layout.idsBin(collection: "docs", segmentId: 7)
        let file = try IdSegmentFile(ids: ["p1", "p2"])
        try IdSegmentFile.write(file, to: url)

        let loaded = try IdSegmentFile.read(from: url)
        XCTAssertEqual(loaded, file)
        XCTAssertTrue(url.path.hasSuffix("collections/docs/segments/7/IDS.bin"))
    }

    func testIdsFlipPayloadFailsCRC() throws {
        var data = try IdSegmentFile.encode(try IdSegmentFile(ids: ["abc", "def"]))
        let payloadIndex = IdSegmentFile.headerByteCount
        data[payloadIndex] ^= 0xFF
        XCTAssertThrowsError(try IdSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted(_, let reason) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(reason.contains("CRC") || reason.contains("truncated") || reason.contains("id"), reason)
        }
    }

    func testIdsFlipCRCTrailerFails() throws {
        var data = try IdSegmentFile.encode(try IdSegmentFile(ids: ["x"]))
        data[data.count - 1] ^= 0x01
        XCTAssertThrowsError(try IdSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testIdsBadMagic() throws {
        var data = try IdSegmentFile.encode(IdSegmentFile.empty)
        data[0] = 0
        XCTAssertThrowsError(try IdSegmentFile.decode(data)) { error in
            guard case VectorSwiftError.corrupted(_, let reason) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(reason.contains("magic"), reason)
        }
    }

    // MARK: - Paired segment

    func testPairedVectorsAndIdsRoundTrip() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        let vectorsURL = layout.vectorsBin(collection: "c", segmentId: 2)
        let idsURL = layout.idsBin(collection: "c", segmentId: 2)

        let vectors = try VectorSegmentFile(
            dimension: 4,
            vectors: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
            ]
        )
        let ids = try IdSegmentFile(ids: ["a", "b", "c"])
        XCTAssertEqual(vectors.count, ids.count)

        try VectorSegmentFile.write(vectors, to: vectorsURL)
        try IdSegmentFile.write(ids, to: idsURL)

        let v2 = try VectorSegmentFile.read(from: vectorsURL)
        let i2 = try IdSegmentFile.read(from: idsURL)
        XCTAssertEqual(v2.count, i2.count)
        XCTAssertEqual(v2, vectors)
        XCTAssertEqual(i2, ids)
    }

    func testMagicBytesAreASCIIFourCC() throws {
        let vData = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 1))
        XCTAssertEqual([UInt8](vData.prefix(4)), [0x56, 0x56, 0x45, 0x43]) // "VVEC"

        let iData = try IdSegmentFile.encode(IdSegmentFile.empty)
        XCTAssertEqual([UInt8](iData.prefix(4)), [0x56, 0x49, 0x44, 0x53]) // "VIDS"
    }
}
