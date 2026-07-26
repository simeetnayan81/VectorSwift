import Foundation

/// Little-endian binary append/read helpers for segment and WAL formats (§7.2–§7.3).
public enum BinaryIO {
    // MARK: - Append

    public static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    public static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    public static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    public static func appendFloat32(_ value: Float, to data: inout Data) {
        appendUInt32(value.bitPattern, to: &data)
    }

    // MARK: - Read

    public static func readUInt16(from data: Data, at offset: inout Int) throws -> UInt16 {
        let raw = try readFixedWidth(from: data, at: &offset, as: UInt16.self)
        return UInt16(littleEndian: raw)
    }

    public static func readUInt32(from data: Data, at offset: inout Int) throws -> UInt32 {
        let raw = try readFixedWidth(from: data, at: &offset, as: UInt32.self)
        return UInt32(littleEndian: raw)
    }

    public static func readUInt64(from data: Data, at offset: inout Int) throws -> UInt64 {
        let raw = try readFixedWidth(from: data, at: &offset, as: UInt64.self)
        return UInt64(littleEndian: raw)
    }

    public static func readFloat32(from data: Data, at offset: inout Int) throws -> Float {
        Float(bitPattern: try readUInt32(from: data, at: &offset))
    }

    // MARK: - Private

    private static func readFixedWidth<T>(
        from data: Data,
        at offset: inout Int,
        as type: T.Type
    ) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else {
            throw BinaryIOError.truncated
        }
        let value: T = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return value
    }
}

public enum BinaryIOError: Error {
    case truncated
}
