import XCTest
import VectorSwiftStorage

final class CRC32Tests: XCTestCase {
    func testEmpty() {
        XCTAssertEqual(CRC32.checksum(Data()), CRC32.emptyChecksum)
        XCTAssertEqual(CRC32.checksum([] as [UInt8]), 0)
        XCTAssertEqual(CRC32.update(0, Data()), 0)
    }

    /// ITU-T V.42 / zlib common check vector (system zlib must match).
    func testKnownVector123456789() {
        let data = Data("123456789".utf8)
        XCTAssertEqual(CRC32.checksum(data), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testUnsafeRawBufferPointerMatchesData() {
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0xFF]
        let data = Data(bytes)
        let viaData = CRC32.checksum(data)
        let viaPointer = bytes.withUnsafeBytes { CRC32.checksum($0) }
        XCTAssertEqual(viaData, viaPointer)
    }

    /// Streaming `update` must match a single-shot `checksum` (WAL-style chunking).
    func testStreamingUpdateMatchesOnesHot() {
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        let oneshot = CRC32.checksum(payload)

        var crc = CRC32.emptyChecksum
        let chunkSize = 137
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            crc = CRC32.update(crc, payload.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertEqual(crc, oneshot)
    }

    func testSegmentBodyCRCStillValidAfterZlibSwitch() throws {
        // Guard wire-format compatibility: encode/decode uses CRC32; must still round-trip.
        let file = try VectorSegmentFile(dimension: 2, vectors: [1, 2, 3, 4])
        let data = try VectorSegmentFile.encode(file)
        let decoded = try VectorSegmentFile.decode(data)
        XCTAssertEqual(decoded, file)
    }
}
