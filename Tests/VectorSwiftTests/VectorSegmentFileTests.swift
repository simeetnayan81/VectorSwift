import XCTest
import VectorSwiftCore
import VectorSwiftStorage

final class VectorSegmentFileTests: XCTestCase {

    private func tempDir(_ label: String = "seg") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    // MARK: - VECTORS.bin round-trip

    func testVectorsEmptyRoundTrip() throws {
        for dim in [1, 2, 4, 16, 384] {
            let file = try VectorSegmentFile.empty(dimension: dim)
            let decoded = try VectorSegmentFile.decode(try VectorSegmentFile.encode(file))
            XCTAssertEqual(decoded.dimension, dim)
            XCTAssertEqual(decoded.count, 0)
            XCTAssertEqual(decoded.vectors, [])
            XCTAssertEqual(decoded.flags, 0)
        }
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

    func testVectorsSpecialFloatBitPatternsRoundTrip() throws {
        let specials: [Float] = [
            0,
            -0.0,
            1,
            -1,
            Float.leastNormalMagnitude,
            Float.leastNonzeroMagnitude,
            Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            Float.infinity,
            -Float.infinity,
            Float.nan, // bit pattern preserved via encode of bitPattern
            Float(bitPattern: 0x7FC0_0001), // quiet NaN payload
        ]
        // Pad to multiple of dim=4
        var vectors = specials
        while vectors.count % 4 != 0 { vectors.append(0) }

        let file = try VectorSegmentFile(dimension: 4, vectors: vectors, flags: 0xA5A5_A5A5)
        let decoded = try VectorSegmentFile.decode(try VectorSegmentFile.encode(file))
        XCTAssertEqual(decoded.flags, 0xA5A5_A5A5)
        XCTAssertEqual(decoded.vectors.count, vectors.count)
        for (a, b) in zip(vectors, decoded.vectors) {
            XCTAssertEqual(
                a.bitPattern,
                b.bitPattern,
                "float bit pattern mismatch \(a.bitPattern) vs \(b.bitPattern)"
            )
        }
    }

    func testVectorsLargerSegmentRoundTrip() throws {
        let dim = 64
        let count = 250
        var vectors = [Float]()
        vectors.reserveCapacity(dim * count)
        for i in 0..<(dim * count) {
            vectors.append(Float(i % 997) * 0.01 - 3.5)
        }
        let file = try VectorSegmentFile(dimension: dim, vectors: vectors, flags: 1)
        let once = try VectorSegmentFile.encode(file)
        let decoded = try VectorSegmentFile.decode(once)
        XCTAssertEqual(decoded, file)

        // Re-encode of decoded must be byte-identical (stable codec).
        let twice = try VectorSegmentFile.encode(decoded)
        XCTAssertEqual(once, twice)
    }

    func testVectorsWriteReadFileAndLayoutPath() throws {
        let root = try tempDir("vectors")
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        let url = layout.vectorsBin(collection: "docs", segmentId: 1)
        let file = try VectorSegmentFile(dimension: 2, vectors: [1.0, 2.0, 3.0, 4.0])
        try VectorSegmentFile.write(file, to: url)

        let loaded = try VectorSegmentFile.read(from: url)
        XCTAssertEqual(loaded, file)
        XCTAssertTrue(url.path.hasSuffix("collections/docs/segments/1/VECTORS.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVectorsOverwriteExistingFile() throws {
        let root = try tempDir("overwrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = DatabaseLayout(root: root).vectorsBin(collection: "c", segmentId: 9)

        try VectorSegmentFile.write(
            try VectorSegmentFile(dimension: 1, vectors: [1, 2, 3]),
            to: url
        )
        try VectorSegmentFile.write(
            try VectorSegmentFile(dimension: 2, vectors: [9, 8]),
            to: url
        )
        let loaded = try VectorSegmentFile.read(from: url)
        XCTAssertEqual(loaded.dimension, 2)
        XCTAssertEqual(loaded.vectors, [9, 8])
    }

    // MARK: - VECTORS.bin validation

    func testVectorsRejectsInvalidInit() {
        XCTAssertThrowsError(try VectorSegmentFile(dimension: 0, vectors: [])) { error in
            guard case VectorSwiftError.invalidArgument = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        XCTAssertThrowsError(try VectorSegmentFile(dimension: 3, vectors: [1, 2])) { error in
            guard case VectorSwiftError.invalidArgument = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        XCTAssertThrowsError(try VectorSegmentFile.empty(dimension: 0))
    }

    func testVectorsWireLayoutHeaderFields() throws {
        let file = try VectorSegmentFile(dimension: 2, vectors: [1.5, -2.25], flags: 7)
        let data = try VectorSegmentFile.encode(file)

        // magic VVEC
        XCTAssertEqual([UInt8](data.prefix(4)), [0x56, 0x56, 0x45, 0x43])
        // version = 1 LE
        XCTAssertEqual(data[4], 1)
        XCTAssertEqual(data[5], 0)
        XCTAssertEqual(data[6], 0)
        XCTAssertEqual(data[7], 0)
        // dim = 2 LE
        XCTAssertEqual(data[8], 2)
        XCTAssertEqual(data[9], 0)
        XCTAssertEqual(data[10], 0)
        XCTAssertEqual(data[11], 0)
        // count = 1 LE u64
        XCTAssertEqual(data[12], 1)
        for i in 13..<20 { XCTAssertEqual(data[i], 0) }
        // flags = 7
        XCTAssertEqual(data[20], 7)
        // reserved = 0
        for i in 24..<28 { XCTAssertEqual(data[i], 0) }
        // total size = header + 2*f32 + crc
        XCTAssertEqual(data.count, VectorSegmentFile.headerByteCount + 8 + 4)
    }

    func testVectorsBadMagic() throws {
        var data = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 2))
        data[0] = 0
        data[1] = 0
        data[2] = 0
        data[3] = 0
        assertCorrupted(try VectorSegmentFile.decode(data), reasonContains: ["magic"])
    }

    func testVectorsUnsupportedVersion() throws {
        var data = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 2))
        data[4] = 99 // version field
        // CRC still covers body only; version is in header so CRC still matches body —
        // decode must reject version before relying on CRC of floats.
        assertCorrupted(try VectorSegmentFile.decode(data), reasonContains: ["version"])
    }

    func testVectorsTruncatedAtBoundaries() throws {
        let full = try VectorSegmentFile.encode(
            try VectorSegmentFile(dimension: 3, vectors: [1, 2, 3, 4, 5, 6])
        )
        // Empty
        assertCorrupted(try VectorSegmentFile.decode(Data()))
        // Only magic
        assertCorrupted(try VectorSegmentFile.decode(Data(full.prefix(4))))
        // Header without CRC
        assertCorrupted(try VectorSegmentFile.decode(Data(full.prefix(VectorSegmentFile.headerByteCount))))
        // Header + partial float payload
        assertCorrupted(try VectorSegmentFile.decode(Data(full.prefix(VectorSegmentFile.headerByteCount + 5))))
        // Missing last CRC byte
        assertCorrupted(try VectorSegmentFile.decode(Data(full.dropLast())))
        // Full is fine
        XCTAssertNoThrow(try VectorSegmentFile.decode(full))
    }

    func testVectorsExtraTrailingBytesFail() throws {
        var data = try VectorSegmentFile.encode(
            try VectorSegmentFile(dimension: 2, vectors: [1, 2])
        )
        data.append(0x00)
        assertCorrupted(try VectorSegmentFile.decode(data), reasonContains: ["size"])
    }

    func testVectorsDeclaredCountMismatch() throws {
        var data = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 2))
        // count at offset 12
        data[12] = 1
        assertCorrupted(try VectorSegmentFile.decode(data))
    }

    func testVectorsFlipEveryPayloadByteFailsCRC() throws {
        let original = try VectorSegmentFile.encode(
            try VectorSegmentFile(dimension: 2, vectors: [1, 2, 3, 4, 5, 6])
        )
        let bodyRange = VectorSegmentFile.headerByteCount..<(original.count - 4)
        XCTAssertFalse(bodyRange.isEmpty)
        for i in bodyRange {
            var data = original
            data[i] ^= 0x01
            assertCorrupted(try VectorSegmentFile.decode(data), reasonContains: ["CRC"])
        }
    }

    func testVectorsFlipCRCTrailerFails() throws {
        let data = try VectorSegmentFile.encode(
            try VectorSegmentFile(dimension: 2, vectors: [1, 2])
        )
        for offset in 1...4 {
            var copy = data
            copy[copy.count - offset] ^= 0xFF
            assertCorrupted(try VectorSegmentFile.decode(copy), reasonContains: ["CRC"])
        }
    }

    func testVectorsReadMissingFileIsIO() {
        let url = URL(fileURLWithPath: "/tmp/vector-swift-definitely-missing-\(UUID().uuidString).bin")
        XCTAssertThrowsError(try VectorSegmentFile.read(from: url)) { error in
            guard case VectorSwiftError.io = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testVectorsReadCorruptionIncludesPath() throws {
        let root = try tempDir("corrupt-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = DatabaseLayout(root: root).vectorsBin(collection: "x", segmentId: 1)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try VectorSegmentFile.encode(try VectorSegmentFile(dimension: 1, vectors: [1]))
        data[VectorSegmentFile.headerByteCount] ^= 0xFF
        try data.write(to: url)

        XCTAssertThrowsError(try VectorSegmentFile.read(from: url)) { error in
            guard case VectorSwiftError.corrupted(let path, _) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(path.contains("VECTORS.bin"), path)
        }
    }

    // MARK: - IDS.bin round-trip

    func testIdsEmptyRoundTrip() throws {
        let decoded = try IdSegmentFile.decode(try IdSegmentFile.encode(IdSegmentFile.empty))
        XCTAssertEqual(decoded.ids, [])
        XCTAssertEqual(decoded.count, 0)
    }

    func testIdsRoundTripUnicodeAndAscii() throws {
        let ids = ["a", "café", "向量", "with space", "emoji-😀", "uuid-ish_01"]
        let file = try IdSegmentFile(ids: ids)
        let decoded = try IdSegmentFile.decode(try IdSegmentFile.encode(file))
        XCTAssertEqual(decoded.ids, ids)
    }

    func testIdsMaxLengthAndManyIdsRoundTrip() throws {
        let maxID = String(repeating: "x", count: VectorSwiftLimits.maxPointIDUTF8ByteCount)
        var ids = [maxID]
        for i in 0..<500 {
            ids.append("id-\(i)")
        }
        let file = try IdSegmentFile(ids: ids)
        let encoded = try IdSegmentFile.encode(file)
        let decoded = try IdSegmentFile.decode(encoded)
        XCTAssertEqual(decoded.ids, ids)
        XCTAssertEqual(try IdSegmentFile.encode(decoded), encoded)
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
        // One bad id among good ones still fails.
        XCTAssertThrowsError(try IdSegmentFile(ids: ["ok", ""]))
    }

    func testIdsWriteReadFile() throws {
        let root = try tempDir("ids")
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        let url = layout.idsBin(collection: "docs", segmentId: 7)
        let file = try IdSegmentFile(ids: ["p1", "p2", "p3"])
        try IdSegmentFile.write(file, to: url)

        let loaded = try IdSegmentFile.read(from: url)
        XCTAssertEqual(loaded, file)
        XCTAssertTrue(url.path.hasSuffix("collections/docs/segments/7/IDS.bin"))
    }

    func testIdsWireMagicAndVersion() throws {
        let data = try IdSegmentFile.encode(try IdSegmentFile(ids: ["z"]))
        XCTAssertEqual([UInt8](data.prefix(4)), [0x56, 0x49, 0x44, 0x53]) // VIDS
        XCTAssertEqual(data[4], 1) // version
        XCTAssertEqual(data[8], 1) // count = 1
    }

    func testIdsBadMagicAndVersion() throws {
        var data = try IdSegmentFile.encode(IdSegmentFile.empty)
        data[0] = 0
        assertCorrupted(try IdSegmentFile.decode(data), reasonContains: ["magic"])

        var data2 = try IdSegmentFile.encode(IdSegmentFile.empty)
        data2[4] = 2
        assertCorrupted(try IdSegmentFile.decode(data2), reasonContains: ["version"])
    }

    func testIdsTruncationAndCRC() throws {
        let full = try IdSegmentFile.encode(try IdSegmentFile(ids: ["abc", "defg"]))
        assertCorrupted(try IdSegmentFile.decode(Data(full.prefix(4))))
        assertCorrupted(try IdSegmentFile.decode(Data(full.prefix(IdSegmentFile.headerByteCount))))
        assertCorrupted(try IdSegmentFile.decode(Data(full.dropLast())))

        var flipped = full
        flipped[IdSegmentFile.headerByteCount] ^= 0xFF
        assertCorrupted(try IdSegmentFile.decode(flipped), reasonContains: ["CRC"])

        var trailer = full
        trailer[trailer.count - 1] ^= 0x01
        assertCorrupted(try IdSegmentFile.decode(trailer), reasonContains: ["CRC"])
    }

    func testIdsCountTooHighAgainstPayload() throws {
        // Encode two ids, bump count to 3 without adding id records → trailing/parse failure after CRC fix attempt.
        var data = try IdSegmentFile.encode(try IdSegmentFile(ids: ["a", "b"]))
        // count is u64 at offset 8
        data[8] = 3
        // Body CRC no longer matches (header excluded), so expect CRC or parse corruption.
        assertCorrupted(try IdSegmentFile.decode(data))
    }

    func testIdsInvalidUTF8WithValidCRC() throws {
        // Build a synthetic file: one id of length 2 with invalid UTF-8 bytes, then correct CRC.
        var data = Data()
        // magic VIDS LE
        data.append(contentsOf: [0x56, 0x49, 0x44, 0x53])
        // version 1
        data.append(contentsOf: [1, 0, 0, 0])
        // count 1
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])
        // id_len = 2, bytes 0xFF 0xFE (invalid UTF-8)
        data.append(contentsOf: [2, 0, 0xFF, 0xFE])
        let body = data.subdata(in: IdSegmentFile.headerByteCount..<data.count)
        var crc = CRC32.checksum(body).littleEndian
        withUnsafeBytes(of: &crc) { data.append(contentsOf: $0) }

        assertCorrupted(try IdSegmentFile.decode(data), reasonContains: ["UTF-8"])
    }

    func testIdsEmptyIdWithValidCRCRejected() throws {
        var data = Data()
        data.append(contentsOf: [0x56, 0x49, 0x44, 0x53])
        data.append(contentsOf: [1, 0, 0, 0])
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])
        // id_len = 0 (empty string) — invalid point id
        data.append(contentsOf: [0, 0])
        let body = data.subdata(in: IdSegmentFile.headerByteCount..<data.count)
        var crc = CRC32.checksum(body).littleEndian
        withUnsafeBytes(of: &crc) { data.append(contentsOf: $0) }

        assertCorrupted(try IdSegmentFile.decode(data), reasonContains: ["id"])
    }

    func testIdsReadMissingFileIsIO() {
        let url = URL(fileURLWithPath: "/tmp/vector-swift-ids-missing-\(UUID().uuidString).bin")
        XCTAssertThrowsError(try IdSegmentFile.read(from: url)) { error in
            guard case VectorSwiftError.io = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    // MARK: - Paired segment consistency

    func testPairedVectorsAndIdsRoundTrip() throws {
        let root = try tempDir("pair")
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        let vectorsURL = layout.vectorsBin(collection: "c", segmentId: 2)
        let idsURL = layout.idsBin(collection: "c", segmentId: 2)

        let n = 100
        let dim = 16
        var floats = [Float]()
        var ids = [String]()
        floats.reserveCapacity(n * dim)
        for i in 0..<n {
            ids.append("row-\(i)")
            for d in 0..<dim {
                floats.append(Float(i * dim + d))
            }
        }

        let vectors = try VectorSegmentFile(dimension: dim, vectors: floats)
        let idFile = try IdSegmentFile(ids: ids)
        XCTAssertEqual(vectors.count, idFile.count)

        try VectorSegmentFile.write(vectors, to: vectorsURL)
        try IdSegmentFile.write(idFile, to: idsURL)

        let v2 = try VectorSegmentFile.read(from: vectorsURL)
        let i2 = try IdSegmentFile.read(from: idsURL)
        XCTAssertEqual(v2.count, i2.count)
        XCTAssertEqual(v2, vectors)
        XCTAssertEqual(i2, idFile)

        // Row alignment: first/last public ids map to vector slices.
        XCTAssertEqual(i2.ids.first, "row-0")
        XCTAssertEqual(i2.ids.last, "row-99")
        XCTAssertEqual(Array(v2.vectors.prefix(dim)), Array(floats.prefix(dim)))
        XCTAssertEqual(Array(v2.vectors.suffix(dim)), Array(floats.suffix(dim)))
    }

    func testLayoutSegmentPaths() {
        let root = URL(fileURLWithPath: "/tmp/vs-root", isDirectory: true)
        let layout = DatabaseLayout(root: root)
        XCTAssertEqual(
            layout.segmentDirectory(collection: "docs", segmentId: 42).lastPathComponent,
            "42"
        )
        XCTAssertTrue(layout.vectorsBin(collection: "docs", segmentId: 42).path.hasSuffix("VECTORS.bin"))
        XCTAssertTrue(layout.idsBin(collection: "docs", segmentId: 42).path.hasSuffix("IDS.bin"))
        XCTAssertNotEqual(
            layout.vectorsBin(collection: "a", segmentId: 1).path,
            layout.vectorsBin(collection: "b", segmentId: 1).path
        )
    }

    func testMagicBytesAreASCIIFourCC() throws {
        let vData = try VectorSegmentFile.encode(try VectorSegmentFile.empty(dimension: 1))
        XCTAssertEqual([UInt8](vData.prefix(4)), [0x56, 0x56, 0x45, 0x43]) // "VVEC"

        let iData = try IdSegmentFile.encode(IdSegmentFile.empty)
        XCTAssertEqual([UInt8](iData.prefix(4)), [0x56, 0x49, 0x44, 0x53]) // "VIDS"
    }
}
