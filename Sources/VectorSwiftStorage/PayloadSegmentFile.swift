import Foundation
import VectorSwiftCore

/// On-disk `PAYLOAD.bin` format — parallel payload maps for sealed rows.
///
/// ```
/// [magic u32 = 'VPLD'] [version u32 = 1] [count u64]
/// for each row:
///   [json_len u32][utf8 JSON object of [String: PayloadValue]]
/// [crc32 u32]   // IEEE CRC-32 over payload after the fixed header
/// ```
///
/// Row order matches `VECTORS.bin` / `IDS.bin`. JSON uses sorted keys.
public struct PayloadSegmentFile: Equatable, Sendable {
    /// Magic `'VPLD'` stored little-endian as u32.
    public static let magic: UInt32 = 0x444C_5056
    public static let formatVersion: UInt32 = 1
    public static let headerByteCount = 16

    public let payloads: [[String: PayloadValue]]

    public var count: Int { payloads.count }

    public init(payloads: [[String: PayloadValue]]) {
        self.payloads = payloads
    }

    public static var empty: PayloadSegmentFile {
        PayloadSegmentFile(payloads: [])
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let jsonDecoder = JSONDecoder()

    // MARK: - Write

    public static func write(_ file: PayloadSegmentFile, to url: URL) throws {
        let data = try encode(file)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to write PAYLOAD.bin at \(url.path): \(error)")
        }
    }

    public static func encode(_ file: PayloadSegmentFile) throws -> Data {
        var data = Data()
        data.reserveCapacity(Self.headerByteCount + file.payloads.count * 32 + 4)

        BinaryIO.appendUInt32(Self.magic, to: &data)
        BinaryIO.appendUInt32(Self.formatVersion, to: &data)
        BinaryIO.appendUInt64(UInt64(file.payloads.count), to: &data)

        for payload in file.payloads {
            let json: Data
            do {
                json = try jsonEncoder.encode(payload)
            } catch {
                throw VectorSwiftError.io("Failed to encode segment payload JSON: \(error)")
            }
            guard json.count <= Int(UInt32.max) else {
                throw VectorSwiftError.invalidArgument("Segment payload JSON too large")
            }
            BinaryIO.appendUInt32(UInt32(json.count), to: &data)
            data.append(json)
        }

        let body = data.subdata(in: Self.headerByteCount..<data.count)
        let crc = CRC32.checksum(body)
        BinaryIO.appendUInt32(crc, to: &data)
        return data
    }

    /// Trailer CRC from an already-encoded blob.
    public static func trailerCRC(of data: Data) throws -> UInt32 {
        guard data.count >= 4 else {
            throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin missing CRC")
        }
        var offset = data.count - 4
        return try BinaryIO.readUInt32(from: data, at: &offset)
    }

    // MARK: - Read

    public static func read(from url: URL) throws -> PayloadSegmentFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VectorSwiftError.io("Failed to read PAYLOAD.bin at \(url.path): \(error)")
        }
        do {
            return try decode(data)
        } catch let error as VectorSwiftError {
            if case .corrupted(let path, let reason) = error, path.isEmpty {
                throw VectorSwiftError.corrupted(path: url.path, reason: reason)
            }
            throw error
        }
    }

    public static func decode(_ data: Data) throws -> PayloadSegmentFile {
        guard data.count >= Self.headerByteCount + 4 else {
            throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin too short (\(data.count) bytes)")
        }

        var offset = 0
        let magic: UInt32
        let version: UInt32
        let countU64: UInt64
        do {
            magic = try BinaryIO.readUInt32(from: data, at: &offset)
            version = try BinaryIO.readUInt32(from: data, at: &offset)
            countU64 = try BinaryIO.readUInt64(from: data, at: &offset)
        } catch {
            throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin truncated header")
        }

        guard magic == Self.magic else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "PAYLOAD.bin bad magic 0x\(String(magic, radix: 16))"
            )
        }
        guard version == Self.formatVersion else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "PAYLOAD.bin unsupported version \(version)"
            )
        }
        guard countU64 <= UInt64(UInt32.max) else {
            throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin count too large")
        }

        let count = Int(countU64)
        let bodyEnd = data.count - 4
        guard bodyEnd >= Self.headerByteCount else {
            throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin missing CRC trailer")
        }

        let body = data.subdata(in: Self.headerByteCount..<bodyEnd)
        let expectedCRC = CRC32.checksum(body)

        var crcOffset = bodyEnd
        let storedCRC: UInt32
        do {
            storedCRC = try BinaryIO.readUInt32(from: data, at: &crcOffset)
        } catch {
            throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin missing CRC trailer")
        }
        guard storedCRC == expectedCRC else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "PAYLOAD.bin CRC mismatch (stored 0x\(String(storedCRC, radix: 16)), computed 0x\(String(expectedCRC, radix: 16)))"
            )
        }

        var payloads: [[String: PayloadValue]] = []
        payloads.reserveCapacity(count)
        offset = Self.headerByteCount
        for _ in 0..<count {
            let jsonLen: UInt32
            do {
                jsonLen = try BinaryIO.readUInt32(from: data, at: &offset)
            } catch {
                throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin truncated json length")
            }
            let len = Int(jsonLen)
            guard offset + len <= bodyEnd else {
                throw VectorSwiftError.corrupted(path: "", reason: "PAYLOAD.bin truncated json bytes")
            }
            let jsonData = data.subdata(in: offset..<(offset + len))
            offset += len
            do {
                let map = try jsonDecoder.decode([String: PayloadValue].self, from: jsonData)
                payloads.append(map)
            } catch {
                throw VectorSwiftError.corrupted(
                    path: "",
                    reason: "PAYLOAD.bin invalid payload JSON: \(error)"
                )
            }
        }

        guard offset == bodyEnd else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "PAYLOAD.bin trailing bytes after \(count) rows"
            )
        }

        return PayloadSegmentFile(payloads: payloads)
    }
}
