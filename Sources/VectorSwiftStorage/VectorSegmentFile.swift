import Foundation
import VectorSwiftCore

/// On-disk `VECTORS.bin` format (design §7.2).
///
/// ```
/// [magic u32 = 'VVEC'] [version u32 = 1] [dim u32] [count u64]
/// [flags u32] [reserved u32]
/// [row 0: dim * f32 LE]
/// ...
/// [row count-1]
/// [crc32 u32]   // IEEE CRC-32 over payload after the fixed header (excludes header + CRC)
/// ```
///
/// All multi-byte integers are little-endian. Vectors are row-major float32.
public struct VectorSegmentFile: Equatable, Sendable {
    /// Magic `'VVEC'` — on-disk bytes `[0x56, 0x56, 0x45, 0x43]`, stored as LE `u32`.
    public static let magic: UInt32 = 0x4345_5656
    public static let formatVersion: UInt32 = 1
    /// Fixed header size in bytes: magic + version + dim + count + flags + reserved.
    public static let headerByteCount = 28

    public let dimension: Int
    public let flags: UInt32
    /// Contiguous row-major vectors: `count * dimension` floats.
    public let vectors: [Float]

    public var count: Int {
        guard dimension > 0 else { return 0 }
        return vectors.count / dimension
    }

    public init(dimension: Int, vectors: [Float], flags: UInt32 = 0) throws {
        guard dimension > 0 else {
            throw VectorSwiftError.invalidArgument("VECTORS.bin dimension must be > 0")
        }
        guard vectors.count % dimension == 0 else {
            throw VectorSwiftError.invalidArgument(
                "VECTORS.bin vector buffer length \(vectors.count) is not a multiple of dimension \(dimension)"
            )
        }
        self.dimension = dimension
        self.flags = flags
        self.vectors = vectors
    }

    /// Empty segment with the given dimension.
    public static func empty(dimension: Int, flags: UInt32 = 0) throws -> VectorSegmentFile {
        try VectorSegmentFile(dimension: dimension, vectors: [], flags: flags)
    }

    // MARK: - Write

    /// Encodes and writes `VECTORS.bin` to `url`.
    public static func write(_ file: VectorSegmentFile, to url: URL) throws {
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
            throw VectorSwiftError.io("Failed to write VECTORS.bin at \(url.path): \(error)")
        }
    }

    /// Encodes a `VECTORS.bin` blob (including trailer CRC).
    public static func encode(_ file: VectorSegmentFile) throws -> Data {
        let count = UInt64(file.count)
        var data = Data()
        data.reserveCapacity(Self.headerByteCount + file.vectors.count * 4 + 4)

        BinaryIO.appendUInt32(Self.magic, to: &data)
        BinaryIO.appendUInt32(Self.formatVersion, to: &data)
        BinaryIO.appendUInt32(UInt32(file.dimension), to: &data)
        BinaryIO.appendUInt64(count, to: &data)
        BinaryIO.appendUInt32(file.flags, to: &data)
        BinaryIO.appendUInt32(0, to: &data) // reserved

        for value in file.vectors {
            BinaryIO.appendFloat32(value, to: &data)
        }

        let body = data.subdata(in: Self.headerByteCount..<data.count)
        let crc = CRC32.checksum(body)
        BinaryIO.appendUInt32(crc, to: &data)
        return data
    }

    // MARK: - Read

    /// Reads and validates a `VECTORS.bin` from `url`.
    public static func read(from url: URL) throws -> VectorSegmentFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VectorSwiftError.io("Failed to read VECTORS.bin at \(url.path): \(error)")
        }
        do {
            return try decode(data)
        } catch let error as VectorSwiftError {
            // Attach path for corruption/IO-style failures when missing.
            if case .corrupted(let path, let reason) = error, path.isEmpty {
                throw VectorSwiftError.corrupted(path: url.path, reason: reason)
            }
            throw error
        }
    }

    /// Decodes and validates a `VECTORS.bin` blob.
    public static func decode(_ data: Data) throws -> VectorSegmentFile {
        guard data.count >= Self.headerByteCount + 4 else {
            throw VectorSwiftError.corrupted(path: "", reason: "VECTORS.bin too short (\(data.count) bytes)")
        }

        var offset = 0
        let magic: UInt32
        let version: UInt32
        let dimU32: UInt32
        let countU64: UInt64
        let flags: UInt32
        let reserved: UInt32
        do {
            magic = try BinaryIO.readUInt32(from: data, at: &offset)
            version = try BinaryIO.readUInt32(from: data, at: &offset)
            dimU32 = try BinaryIO.readUInt32(from: data, at: &offset)
            countU64 = try BinaryIO.readUInt64(from: data, at: &offset)
            flags = try BinaryIO.readUInt32(from: data, at: &offset)
            reserved = try BinaryIO.readUInt32(from: data, at: &offset)
        } catch {
            throw VectorSwiftError.corrupted(path: "", reason: "VECTORS.bin truncated header")
        }
        _ = reserved

        guard magic == Self.magic else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "VECTORS.bin bad magic 0x\(String(magic, radix: 16))"
            )
        }
        guard version == Self.formatVersion else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "VECTORS.bin unsupported version \(version)"
            )
        }
        guard dimU32 > 0 else {
            throw VectorSwiftError.corrupted(path: "", reason: "VECTORS.bin dimension is 0")
        }
        // Prevent absurd allocations from corrupt count.
        guard countU64 <= UInt64(UInt32.max) else {
            throw VectorSwiftError.corrupted(path: "", reason: "VECTORS.bin count too large")
        }

        let dimension = Int(dimU32)
        let count = Int(countU64)
        let floatsByteCount = count * dimension * MemoryLayout<Float>.size
        let expectedTotal = Self.headerByteCount + floatsByteCount + 4
        guard data.count == expectedTotal else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "VECTORS.bin size mismatch: got \(data.count), expected \(expectedTotal)"
            )
        }

        let bodyStart = Self.headerByteCount
        let bodyEnd = data.count - 4
        let body = data.subdata(in: bodyStart..<bodyEnd)
        let expectedCRC = CRC32.checksum(body)

        var crcOffset = bodyEnd
        let storedCRC: UInt32
        do {
            storedCRC = try BinaryIO.readUInt32(from: data, at: &crcOffset)
        } catch {
            throw VectorSwiftError.corrupted(path: "", reason: "VECTORS.bin missing CRC trailer")
        }
        guard storedCRC == expectedCRC else {
            throw VectorSwiftError.corrupted(
                path: "",
                reason: "VECTORS.bin CRC mismatch (stored 0x\(String(storedCRC, radix: 16)), computed 0x\(String(expectedCRC, radix: 16)))"
            )
        }

        var vectors = [Float]()
        vectors.reserveCapacity(count * dimension)
        offset = bodyStart
        for _ in 0..<(count * dimension) {
            do {
                vectors.append(try BinaryIO.readFloat32(from: data, at: &offset))
            } catch {
                throw VectorSwiftError.corrupted(path: "", reason: "VECTORS.bin truncated float payload")
            }
        }

        return try VectorSegmentFile(dimension: dimension, vectors: vectors, flags: flags)
    }
}
