import Foundation
import VectorSwiftCore

/// On-disk `IDS.bin` format (design §7.2).
///
/// ```
/// [magic u32 = 'VIDS'] [version u32 = 1] [count u64]
/// for each row:
///   [id_len u16][id utf8 bytes]
/// [crc32 u32]   // IEEE CRC-32 over payload after the fixed header (excludes header + CRC)
/// ```
///
/// All multi-byte integers are little-endian. Parallel to `VECTORS.bin` by row index.
public struct IdSegmentFile: Equatable, Sendable {
    /// Magic bytes `'VIDS'` stored little-endian as u32 (`[V,I,D,S]` on disk).
    public static let magic: UInt32 = 0x5344_4956
    public static let formatVersion: UInt32 = 1
    /// Fixed header size: magic + version + count.
    public static let headerByteCount = 16

    public let ids: [PointID]

    public var count: Int { ids.count }

    public init(ids: [PointID]) throws {
        for id in ids {
            try VectorValidation.requirePointID(id)
            // id_len is u16; max point id is 512 which fits.
            let utf8Count = id.utf8.count
            guard utf8Count <= UInt16.max else {
                throw VectorSwiftError.invalidPointID(id)
            }
        }
        self.ids = ids
    }

    public static var empty: IdSegmentFile {
        // Safe: no ids to validate.
        try! IdSegmentFile(ids: [])
    }

    // MARK: - Write

    public static func write(_ file: IdSegmentFile, to url: URL) throws {
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
            throw VectorSwiftError.io("Failed to write IDS.bin at \(url.path): \(error)")
        }
    }

    public static func encode(_ file: IdSegmentFile) throws -> Data {
        var data = Data()
        // Rough reserve: header + ~16 bytes average id + crc.
        data.reserveCapacity(Self.headerByteCount + file.ids.count * 16 + 4)

        BinaryIO.appendUInt32(Self.magic, to: &data)
        BinaryIO.appendUInt32(Self.formatVersion, to: &data)
        BinaryIO.appendUInt64(UInt64(file.ids.count), to: &data)

        for id in file.ids {
            let utf8 = Array(id.utf8)
            BinaryIO.appendUInt16(UInt16(utf8.count), to: &data)
            data.append(contentsOf: utf8)
        }

        let body = data.subdata(in: Self.headerByteCount..<data.count)
        let crc = CRC32.checksum(body)
        BinaryIO.appendUInt32(crc, to: &data)
        return data
    }

    // MARK: - Read

    public static func read(from url: URL) throws -> IdSegmentFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VectorSwiftError.io("Failed to read IDS.bin at \(url.path): \(error)")
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

    public static func decode(_ data: Data) throws -> IdSegmentFile {
        guard data.count >= Self.headerByteCount + 4 else {
            throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin too short (\(data.count) bytes)")
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
            throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin truncated header")
        }

        guard magic == Self.magic else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "IDS.bin bad magic 0x\(String(magic, radix: 16))"
            )
        }
        guard version == Self.formatVersion else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "IDS.bin unsupported version \(version)"
            )
        }
        guard countU64 <= UInt64(UInt32.max) else {
            throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin count too large")
        }

        let count = Int(countU64)
        let bodyEnd = data.count - 4
        guard bodyEnd >= Self.headerByteCount else {
            throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin missing CRC trailer")
        }

        let body = data.subdata(in: Self.headerByteCount..<bodyEnd)
        let expectedCRC = CRC32.checksum(body)

        var crcOffset = bodyEnd
        let storedCRC: UInt32
        do {
            storedCRC = try BinaryIO.readUInt32(from: data, at: &crcOffset)
        } catch {
            throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin missing CRC trailer")
        }
        guard storedCRC == expectedCRC else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "IDS.bin CRC mismatch (stored 0x\(String(storedCRC, radix: 16)), computed 0x\(String(expectedCRC, radix: 16)))"
            )
        }

        var ids: [PointID] = []
        ids.reserveCapacity(count)
        offset = Self.headerByteCount
        for _ in 0..<count {
            let idLen: UInt16
            do {
                idLen = try BinaryIO.readUInt16(from: data, at: &offset)
            } catch {
                throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin truncated id length")
            }
            let len = Int(idLen)
            guard offset + len <= bodyEnd else {
                throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin truncated id bytes")
            }
            let idData = data.subdata(in: offset..<(offset + len))
            offset += len
            guard let id = String(data: idData, encoding: .utf8) else {
                throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin id is not valid UTF-8")
            }
            do {
                try VectorValidation.requirePointID(id)
            } catch {
                throw VectorSwiftError.corrupted(path: "", reason: "IDS.bin invalid point id")
            }
            ids.append(id)
        }

        guard offset == bodyEnd else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "IDS.bin trailing bytes after \(count) ids (offset \(offset), bodyEnd \(bodyEnd))"
            )
        }

        return try IdSegmentFile(ids: ids)
    }
}
