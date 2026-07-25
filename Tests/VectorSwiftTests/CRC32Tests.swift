import XCTest
import VectorSwiftStorage

final class CRC32Tests: XCTestCase {

    // MARK: - Known vectors (IEEE / zlib)

    func testEmpty() {
        XCTAssertEqual(CRC32.checksum(Data()), CRC32.emptyChecksum)
        XCTAssertEqual(CRC32.checksum([] as [UInt8]), 0)
        XCTAssertEqual(CRC32.update(0, Data()), 0)
        XCTAssertEqual(CRC32.update(CRC32.emptyChecksum, Data()), 0)
    }

    /// ITU-T V.42 / zlib check vector.
    func testKnownVector123456789() {
        let data = Data("123456789".utf8)
        XCTAssertEqual(CRC32.checksum(data), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testKnownSingleBytes() {
        // Reference values from zlib CRC-32 of single-byte inputs.
        XCTAssertEqual(CRC32.checksum([0x00]), 0xD202_EF8D)
        XCTAssertEqual(CRC32.checksum([0xFF]), 0xFF00_0000)
        XCTAssertEqual(CRC32.checksum([0x01]), 0xA505_DF1B)
    }

    func testKnownShortStrings() {
        XCTAssertEqual(CRC32.checksum(Data("a".utf8)), 0xE8B7_BE43)
        XCTAssertEqual(CRC32.checksum(Data("abc".utf8)), 0x3524_41C2)
        XCTAssertEqual(CRC32.checksum(Data("".utf8)), 0)
    }

    // MARK: - API surface agreement

    func testDataPointerAndSequenceAgree() {
        let patterns: [[UInt8]] = [
            [],
            [0],
            [0xFF],
            [1, 2, 3, 4, 5],
            Array(0..<255),
            Array(repeating: 0xA5, count: 4097),
        ]
        for bytes in patterns {
            let data = Data(bytes)
            let viaData = CRC32.checksum(data)
            let viaPointer = bytes.withUnsafeBytes { CRC32.checksum($0) }
            let viaSequence = CRC32.checksum(bytes)
            // Non-Array Sequence path (lazy map) exercises chunked sequence implementation.
            let viaLazy = CRC32.checksum(bytes.lazy.map { $0 })
            XCTAssertEqual(viaData, viaPointer, "pointer mismatch for \(bytes.count) bytes")
            XCTAssertEqual(viaData, viaSequence, "sequence mismatch for \(bytes.count) bytes")
            XCTAssertEqual(viaData, viaLazy, "lazy sequence mismatch for \(bytes.count) bytes")
        }
    }

    // MARK: - Streaming

    func testStreamingMatchesOneshotAcrossChunkSizes() {
        let payload = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        let oneshot = CRC32.checksum(payload)

        for chunkSize in [1, 2, 3, 7, 64, 137, 1024, 4096, payload.count, payload.count + 100] {
            var crc = CRC32.emptyChecksum
            var offset = 0
            while offset < payload.count {
                let end = min(offset + chunkSize, payload.count)
                crc = CRC32.update(crc, payload.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(crc, oneshot, "chunkSize=\(chunkSize)")
        }
    }

    func testStreamingEmptyChunksAreNoOps() {
        let body = Data("hello-vector-swift".utf8)
        let expected = CRC32.checksum(body)

        var crc = CRC32.emptyChecksum
        crc = CRC32.update(crc, Data())
        crc = CRC32.update(crc, body)
        crc = CRC32.update(crc, Data())
        XCTAssertEqual(crc, expected)
    }

    func testStreamingAssociativity() {
        let a = Data("part-a-".utf8)
        let b = Data("part-b-".utf8)
        let c = Data("part-c".utf8)
        let all = a + b + c

        let left = CRC32.update(CRC32.update(CRC32.checksum(a), b), c)
        let right = CRC32.checksum(all)
        let mid = CRC32.update(CRC32.checksum(a + b), c)
        XCTAssertEqual(left, right)
        XCTAssertEqual(mid, right)
    }

    // MARK: - Determinism & sensitivity

    func testDeterministicAcrossRuns() {
        let data = Data((0..<1024).map { UInt8($0 % 251) })
        let first = CRC32.checksum(data)
        for _ in 0..<20 {
            XCTAssertEqual(CRC32.checksum(data), first)
        }
    }

    func testSingleBitFlipChangesChecksum() {
        var bytes = Array(repeating: UInt8(0), count: 64)
        bytes[31] = 0x00
        let base = CRC32.checksum(bytes)
        bytes[31] = 0x01
        let flipped = CRC32.checksum(bytes)
        XCTAssertNotEqual(base, flipped)
    }

    func testLargeBuffer() {
        // ~1 MiB — exercises chunking path safety and performance sanity.
        let size = 1 << 20
        var bytes = [UInt8](repeating: 0, count: size)
        for i in stride(from: 0, to: size, by: 97) {
            bytes[i] = UInt8(truncatingIfNeeded: i)
        }
        let crc = CRC32.checksum(Data(bytes))
        // Streaming in 8 KiB chunks must match.
        var streamed = CRC32.emptyChecksum
        let chunk = 8192
        var offset = 0
        let data = Data(bytes)
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            streamed = CRC32.update(streamed, data.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertEqual(crc, streamed)
        // Non-zero for non-empty patterned data (weak sanity).
        XCTAssertNotEqual(crc, 0)
    }

    func testSegmentEncodeUsesCRCConsistently() throws {
        let file = try VectorSegmentFile(
            dimension: 8,
            vectors: (0..<64).map { Float($0) * 0.125 }
        )
        let data = try VectorSegmentFile.encode(file)
        // Trailer must equal CRC of body after header.
        let body = data.subdata(in: VectorSegmentFile.headerByteCount..<(data.count - 4))
        let trailer = data.suffix(4).withUnsafeBytes { buf in
            UInt32(littleEndian: buf.load(as: UInt32.self))
        }
        XCTAssertEqual(CRC32.checksum(body), trailer)
        XCTAssertEqual(try VectorSegmentFile.decode(data), file)
    }
}
