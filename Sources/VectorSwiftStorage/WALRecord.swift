import Foundation
import VectorSwiftCore

/// WAL record type byte values (design §7.3, ADR-001).
public enum WALRecordType: UInt8, Sendable, Equatable {
    case upsert = 1
    case delete = 2
    case checkpointMark = 3
    /// Legacy seal placeholder (segment id only). Writers emit ``sealSegmentV2``.
    case sealSegment = 4
    /// Seal with checksums (mutable segment flush).
    case sealSegmentV2 = 5
}

/// Checksums and identity for a sealed segment (WAL type 5 payload).
public struct WALSealSegmentV2Payload: Equatable, Sendable {
    public var segmentId: UInt64
    public var rowCount: UInt64
    public var vectorsCrc32: UInt32
    public var idsCrc32: UInt32
    public var payloadsCrc32: UInt32
    public var flags: UInt32

    public init(
        segmentId: UInt64,
        rowCount: UInt64,
        vectorsCrc32: UInt32,
        idsCrc32: UInt32,
        payloadsCrc32: UInt32,
        flags: UInt32 = 0
    ) {
        self.segmentId = segmentId
        self.rowCount = rowCount
        self.vectorsCrc32 = vectorsCrc32
        self.idsCrc32 = idsCrc32
        self.payloadsCrc32 = payloadsCrc32
        self.flags = flags
    }

    /// On-disk payload size: 8+8+4+4+4+4.
    public static let byteCount = 32
}

/// One logical write-ahead log operation.
///
/// Framed on disk as:
/// ```
/// [len u32]  // bytes after len through crc (type + payload + crc)
/// [type u8]
/// [payload bytes]
/// [crc32 u32]  // IEEE CRC-32 over type+payload
/// ```
public enum WALRecord: Equatable, Sendable {
    /// Insert or replace a point. Vector is stored as already-normalized when applicable.
    case upsert(id: PointID, vector: [Float], payload: [String: PayloadValue])
    /// Delete live points by public id (unknown ids are ignored on apply).
    case delete(ids: [PointID])
    /// Marks a durability checkpoint (no payload in v1).
    case checkpointMark
    /// Legacy seal placeholder (segment id only). Prefer ``sealSegmentV2``.
    case sealSegment(segmentId: UInt64)
    /// Seal record with segment checksums (full snapshot seal).
    case sealSegmentV2(WALSealSegmentV2Payload)

    public var recordType: WALRecordType {
        switch self {
        case .upsert: return .upsert
        case .delete: return .delete
        case .checkpointMark: return .checkpointMark
        case .sealSegment: return .sealSegment
        case .sealSegmentV2: return .sealSegmentV2
        }
    }
}

/// Encode / decode helpers for WAL record frames and type-specific payloads.
public enum WALCodec {
    private static let payloadJSONEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let payloadJSONDecoder = JSONDecoder()

    // MARK: - Frame encode

    /// Encodes a full framed record: `[len][type][payload][crc]`.
    public static func encodeFrame(_ record: WALRecord) throws -> Data {
        let typeByte = record.recordType.rawValue
        let payload = try encodePayload(record)

        var body = Data()
        body.reserveCapacity(1 + payload.count)
        body.append(typeByte)
        body.append(payload)

        let crc = CRC32.checksum(body)
        let len = UInt32(body.count + 4) // type+payload+crc

        var frame = Data()
        frame.reserveCapacity(4 + body.count + 4)
        BinaryIO.appendUInt32(len, to: &frame)
        frame.append(body)
        BinaryIO.appendUInt32(crc, to: &frame)
        return frame
    }

    // MARK: - Frame decode (from buffer)

    /// Result of attempting to read one record at `offset`.
    public enum FrameRead: Equatable, Sendable {
        /// Complete valid record; `nextOffset` is past the frame.
        case record(WALRecord, nextOffset: Int)
        /// Not enough bytes for a complete frame starting at this offset (torn tail).
        case incompleteTail
    }

    /// Attempts to decode one framed record starting at `offset` in `data`.
    ///
    /// - Returns: `.record` on success, `.incompleteTail` when the declared length
    ///   exceeds remaining bytes (caller should truncate the file to `offset`).
    /// - Throws: `VectorSwiftError.corrupted` for CRC failures, unknown types, or
    ///   malformed payloads when the full frame is present.
    public static func readFrame(
        from data: Data,
        at offset: Int,
        path: String = ""
    ) throws -> FrameRead {
        let remaining = data.count - offset
        if remaining == 0 {
            return .incompleteTail
        }
        // Need at least len field.
        if remaining < 4 {
            return .incompleteTail
        }

        var cursor = offset
        let len: UInt32
        do {
            len = try BinaryIO.readUInt32(from: data, at: &cursor)
        } catch {
            return .incompleteTail
        }

        // Minimum: type(1) + crc(4) = 5
        guard len >= 5 else {
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL record length \(len) is too small"
            )
        }
        // Cap absurd lengths to avoid huge allocations from corrupt data.
        guard len <= UInt32(16 * 1024 * 1024) else {
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL record length \(len) exceeds 16 MiB limit"
            )
        }

        let frameBodyEnd = cursor + Int(len)
        if frameBodyEnd > data.count {
            return .incompleteTail
        }

        let bodyAndCRC = data.subdata(in: cursor..<frameBodyEnd)
        // bodyAndCRC = type + payload + crc
        let crcStart = bodyAndCRC.count - 4
        let body = bodyAndCRC.subdata(in: 0..<crcStart)
        var crcOffset = crcStart
        let storedCRC: UInt32
        do {
            storedCRC = try BinaryIO.readUInt32(from: bodyAndCRC, at: &crcOffset)
        } catch {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL missing CRC trailer")
        }

        let computedCRC = CRC32.checksum(body)
        guard storedCRC == computedCRC else {
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL CRC mismatch (stored 0x\(String(storedCRC, radix: 16)), computed 0x\(String(computedCRC, radix: 16)))"
            )
        }

        guard let typeByte = body.first,
              let type = WALRecordType(rawValue: typeByte)
        else {
            let raw = body.first.map { String($0) } ?? "none"
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL unknown or missing record type byte (\(raw))"
            )
        }

        let payload = body.count > 1 ? body.subdata(in: 1..<body.count) : Data()
        let record = try decodePayload(type: type, payload: payload, path: path)
        return .record(record, nextOffset: frameBodyEnd)
    }

    // MARK: - Payload

    public static func encodePayload(_ record: WALRecord) throws -> Data {
        switch record {
        case .upsert(let id, let vector, let payload):
            return try encodeUpsertPayload(id: id, vector: vector, payload: payload)
        case .delete(let ids):
            return try encodeDeletePayload(ids: ids)
        case .checkpointMark:
            return Data()
        case .sealSegment(let segmentId):
            var data = Data()
            BinaryIO.appendUInt64(segmentId, to: &data)
            return data
        case .sealSegmentV2(let seal):
            var data = Data()
            data.reserveCapacity(WALSealSegmentV2Payload.byteCount)
            BinaryIO.appendUInt64(seal.segmentId, to: &data)
            BinaryIO.appendUInt64(seal.rowCount, to: &data)
            BinaryIO.appendUInt32(seal.vectorsCrc32, to: &data)
            BinaryIO.appendUInt32(seal.idsCrc32, to: &data)
            BinaryIO.appendUInt32(seal.payloadsCrc32, to: &data)
            BinaryIO.appendUInt32(seal.flags, to: &data)
            return data
        }
    }

    public static func decodePayload(
        type: WALRecordType,
        payload: Data,
        path: String = ""
    ) throws -> WALRecord {
        switch type {
        case .upsert:
            return try decodeUpsertPayload(payload, path: path)
        case .delete:
            return try decodeDeletePayload(payload, path: path)
        case .checkpointMark:
            guard payload.isEmpty else {
                throw VectorSwiftError.corrupted(
                    path: path,
                    reason: "WAL checkpoint_mark payload must be empty"
                )
            }
            return .checkpointMark
        case .sealSegment:
            guard payload.count == 8 else {
                throw VectorSwiftError.corrupted(
                    path: path,
                    reason: "WAL seal_segment payload must be 8 bytes, got \(payload.count)"
                )
            }
            var offset = 0
            let segmentId = try BinaryIO.readUInt64(from: payload, at: &offset)
            return .sealSegment(segmentId: segmentId)
        case .sealSegmentV2:
            guard payload.count == WALSealSegmentV2Payload.byteCount else {
                throw VectorSwiftError.corrupted(
                    path: path,
                    reason: "WAL seal_segment_v2 payload must be \(WALSealSegmentV2Payload.byteCount) bytes, got \(payload.count)"
                )
            }
            var offset = 0
            let segmentId = try BinaryIO.readUInt64(from: payload, at: &offset)
            let rowCount = try BinaryIO.readUInt64(from: payload, at: &offset)
            let vectorsCrc = try BinaryIO.readUInt32(from: payload, at: &offset)
            let idsCrc = try BinaryIO.readUInt32(from: payload, at: &offset)
            let payloadsCrc = try BinaryIO.readUInt32(from: payload, at: &offset)
            let flags = try BinaryIO.readUInt32(from: payload, at: &offset)
            return .sealSegmentV2(
                WALSealSegmentV2Payload(
                    segmentId: segmentId,
                    rowCount: rowCount,
                    vectorsCrc32: vectorsCrc,
                    idsCrc32: idsCrc,
                    payloadsCrc32: payloadsCrc,
                    flags: flags
                )
            )
        }
    }

    // MARK: - Upsert payload

    /// `[id_len u16][id UTF-8][dim u32][dim×f32 LE][payload_json_len u32][JSON UTF-8]`
    private static func encodeUpsertPayload(
        id: PointID,
        vector: [Float],
        payload: [String: PayloadValue]
    ) throws -> Data {
        try VectorValidation.requirePointID(id)
        let idUTF8 = Array(id.utf8)
        guard idUTF8.count <= UInt16.max else {
            throw VectorSwiftError.invalidPointID(id)
        }
        guard vector.count <= Int(UInt32.max) else {
            throw VectorSwiftError.invalidArgument("WAL upsert vector dimension too large")
        }

        let jsonData: Data
        do {
            jsonData = try payloadJSONEncoder.encode(payload)
        } catch {
            throw VectorSwiftError.io("Failed to encode WAL upsert payload JSON: \(error)")
        }
        guard jsonData.count <= Int(UInt32.max) else {
            throw VectorSwiftError.invalidArgument("WAL upsert payload JSON too large")
        }

        var data = Data()
        data.reserveCapacity(2 + idUTF8.count + 4 + vector.count * 4 + 4 + jsonData.count)
        BinaryIO.appendUInt16(UInt16(idUTF8.count), to: &data)
        data.append(contentsOf: idUTF8)
        BinaryIO.appendUInt32(UInt32(vector.count), to: &data)
        for value in vector {
            BinaryIO.appendFloat32(value, to: &data)
        }
        BinaryIO.appendUInt32(UInt32(jsonData.count), to: &data)
        data.append(jsonData)
        return data
    }

    private static func decodeUpsertPayload(_ payload: Data, path: String) throws -> WALRecord {
        var offset = 0
        let idLen: UInt16
        do {
            idLen = try BinaryIO.readUInt16(from: payload, at: &offset)
        } catch {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated id length")
        }
        guard offset + Int(idLen) <= payload.count else {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated id bytes")
        }
        let idData = payload.subdata(in: offset..<(offset + Int(idLen)))
        offset += Int(idLen)
        guard let id = String(data: idData, encoding: .utf8) else {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert id is not valid UTF-8")
        }
        do {
            try VectorValidation.requirePointID(id)
        } catch {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert invalid point id")
        }

        let dimU32: UInt32
        do {
            dimU32 = try BinaryIO.readUInt32(from: payload, at: &offset)
        } catch {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated dim")
        }
        let dim = Int(dimU32)
        // Bound dim to avoid huge allocations.
        guard dim >= 0, dim <= 65_536 else {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert dim out of range (\(dim))")
        }
        guard offset + dim * 4 <= payload.count else {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated vector")
        }
        var vector = [Float]()
        vector.reserveCapacity(dim)
        for _ in 0..<dim {
            do {
                vector.append(try BinaryIO.readFloat32(from: payload, at: &offset))
            } catch {
                throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated float")
            }
        }

        let jsonLenU32: UInt32
        do {
            jsonLenU32 = try BinaryIO.readUInt32(from: payload, at: &offset)
        } catch {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated payload length")
        }
        let jsonLen = Int(jsonLenU32)
        guard offset + jsonLen <= payload.count else {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL upsert truncated payload JSON")
        }
        // Reject trailing junk after declared payload.
        guard offset + jsonLen == payload.count else {
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL upsert payload has trailing \(payload.count - offset - jsonLen) bytes"
            )
        }
        let jsonData = payload.subdata(in: offset..<(offset + jsonLen))
        let map: [String: PayloadValue]
        do {
            map = try payloadJSONDecoder.decode([String: PayloadValue].self, from: jsonData)
        } catch {
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL upsert invalid payload JSON: \(error)"
            )
        }
        return .upsert(id: id, vector: vector, payload: map)
    }

    // MARK: - Delete payload

    /// `[count u32]` then `count × [id_len u16][id UTF-8]`
    private static func encodeDeletePayload(ids: [PointID]) throws -> Data {
        guard ids.count <= Int(UInt32.max) else {
            throw VectorSwiftError.invalidArgument("WAL delete id list too large")
        }
        var data = Data()
        BinaryIO.appendUInt32(UInt32(ids.count), to: &data)
        for id in ids {
            try VectorValidation.requirePointID(id)
            let utf8 = Array(id.utf8)
            guard utf8.count <= UInt16.max else {
                throw VectorSwiftError.invalidPointID(id)
            }
            BinaryIO.appendUInt16(UInt16(utf8.count), to: &data)
            data.append(contentsOf: utf8)
        }
        return data
    }

    private static func decodeDeletePayload(_ payload: Data, path: String) throws -> WALRecord {
        var offset = 0
        let countU32: UInt32
        do {
            countU32 = try BinaryIO.readUInt32(from: payload, at: &offset)
        } catch {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL delete truncated count")
        }
        let count = Int(countU32)
        guard count >= 0, count <= 1_000_000 else {
            throw VectorSwiftError.corrupted(path: path, reason: "WAL delete count out of range")
        }
        var ids: [PointID] = []
        ids.reserveCapacity(count)
        for _ in 0..<count {
            let idLen: UInt16
            do {
                idLen = try BinaryIO.readUInt16(from: payload, at: &offset)
            } catch {
                throw VectorSwiftError.corrupted(path: path, reason: "WAL delete truncated id length")
            }
            guard offset + Int(idLen) <= payload.count else {
                throw VectorSwiftError.corrupted(path: path, reason: "WAL delete truncated id bytes")
            }
            let idData = payload.subdata(in: offset..<(offset + Int(idLen)))
            offset += Int(idLen)
            guard let id = String(data: idData, encoding: .utf8) else {
                throw VectorSwiftError.corrupted(path: path, reason: "WAL delete id is not valid UTF-8")
            }
            do {
                try VectorValidation.requirePointID(id)
            } catch {
                throw VectorSwiftError.corrupted(path: path, reason: "WAL delete invalid point id")
            }
            ids.append(id)
        }
        guard offset == payload.count else {
            throw VectorSwiftError.corrupted(
                path: path,
                reason: "WAL delete payload has trailing \(payload.count - offset) bytes"
            )
        }
        return .delete(ids: ids)
    }
}
