import Foundation
import CZlib

/// IEEE CRC-32 (ISO 3309 / ITU-T V.42) via system **zlib** (`crc32`).
///
/// Used for on-disk integrity: `VECTORS.bin` / `IDS.bin` trailers (S12), and per-record
/// checksums in the WAL (S13+). Links OS `libz` through the `CZlib` system module
/// (portable on Linux where bare `import zlib` is unavailable).
///
/// Polynomial matches the common check vector `"123456789"` → `0xCBF43926`.
public enum CRC32 {
    /// CRC-32 of an empty buffer (`crc32(0, NULL, 0)`).
    public static let emptyChecksum: UInt32 = 0

    /// Initial value for streaming updates. Pass the result of prior `update` calls back in.
    ///
    /// Start a new stream with `CRC32.emptyChecksum` (or `0`), then call `update` for each chunk.
    public static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { update(crc, $0) }
    }

    /// Streaming update over a raw buffer. Safe for large buffers (chunks at `UInt32.max` of `uInt`).
    public static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = bytes.bindMemory(to: Bytef.self).baseAddress else {
            // Empty or nil base: zlib returns the same crc for length 0.
            return UInt32(truncatingIfNeeded: crc32(uLong(crc), nil, 0))
        }
        var running = uLong(crc)
        var remaining = bytes.count
        var ptr = base
        // `uInt` is often 32-bit; chunk so very large segments still work.
        let maxChunk = Int(UInt32.max)
        while remaining > 0 {
            let chunk = min(remaining, maxChunk)
            running = crc32(running, ptr, uInt(chunk))
            ptr = ptr.advanced(by: chunk)
            remaining -= chunk
        }
        return UInt32(truncatingIfNeeded: running)
    }

    /// Computes the IEEE CRC-32 of `data` (full buffer, non-streaming).
    public static func checksum(_ data: Data) -> UInt32 {
        update(emptyChecksum, data)
    }

    /// Computes the IEEE CRC-32 of raw bytes.
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        update(emptyChecksum, bytes)
    }

    /// Computes the IEEE CRC-32 of a byte sequence without requiring `Data`.
    ///
    /// Prefer `checksum(Data)` / `checksum(UnsafeRawBufferPointer)` for large contiguous buffers;
    /// this path exists for small test helpers and sparse sequences.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        // Contiguous fast path when the sequence is already an Array.
        if let array = bytes as? [UInt8] {
            return array.withUnsafeBytes { checksum($0) }
        }
        var crc = emptyChecksum
        var chunk = [UInt8]()
        chunk.reserveCapacity(4096)
        for byte in bytes {
            chunk.append(byte)
            if chunk.count == 4096 {
                crc = chunk.withUnsafeBytes { update(crc, $0) }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            crc = chunk.withUnsafeBytes { update(crc, $0) }
        }
        return crc
    }
}
