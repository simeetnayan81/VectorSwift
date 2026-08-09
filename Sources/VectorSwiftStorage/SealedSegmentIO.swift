import Foundation
import VectorSwiftCore

/// Helpers for writing and loading a complete sealed segment directory.
public enum SealedSegmentIO {
    /// One in-memory row destined for a sealed segment (parallel arrays).
    public struct Row: Sendable {
        public var id: PointID
        public var vector: [Float]
        public var payload: [String: PayloadValue]

        public init(id: PointID, vector: [Float], payload: [String: PayloadValue]) {
            self.id = id
            self.vector = vector
            self.payload = payload
        }
    }

    /// Result of a successful segment write.
    public struct WriteResult: Sendable {
        public var segmentId: UInt64
        public var rowCount: UInt64
        public var vectorsCrc32: UInt32
        public var idsCrc32: UInt32
        public var payloadsCrc32: UInt32
        public var tombstonesCrc32: UInt32
        public var meta: SegmentMetaDocument
    }

    /// Loaded segment contents after validating meta + CRCs.
    public struct LoadResult: Sendable {
        public var rows: [Row]
        public var tombstones: [PointID]
        public var meta: SegmentMetaDocument
    }

    /// Writes VECTORS / IDS / PAYLOAD / TOMBSTONES / SEGMENT_META under `segmentDirectory`.
    ///
    /// `SEGMENT_META.json` is written last so incomplete directories are detectable.
    /// `tombstones` are public ids deleted during this mutable epoch (not live in `rows`).
    public static func writeSegment(
        segmentId: UInt64,
        dimension: Int,
        index: IndexConfig,
        rows: [Row],
        tombstones: [PointID] = [],
        segmentDirectory: URL,
        vectorsURL: URL,
        idsURL: URL,
        payloadURL: URL,
        tombstonesURL: URL,
        metaURL: URL
    ) throws -> WriteResult {
        guard dimension >= 1 else {
            throw VectorSwiftError.invalidArgument("segment dimension must be >= 1")
        }

        var vectors: [Float] = []
        vectors.reserveCapacity(rows.count * dimension)
        var ids: [PointID] = []
        ids.reserveCapacity(rows.count)
        var payloads: [[String: PayloadValue]] = []
        payloads.reserveCapacity(rows.count)

        for row in rows {
            guard row.vector.count == dimension else {
                throw VectorSwiftError.invalidDimension(
                    expected: dimension,
                    actual: row.vector.count
                )
            }
            vectors.append(contentsOf: row.vector)
            ids.append(row.id)
            payloads.append(row.payload)
        }

        try FileManager.default.createDirectory(
            at: segmentDirectory,
            withIntermediateDirectories: true
        )

        let vectorsFile = try VectorSegmentFile(dimension: dimension, vectors: vectors)
        let idsFile = try IdSegmentFile(ids: ids)
        let payloadFile = PayloadSegmentFile(payloads: payloads)
        let tombstonesFile = try IdSegmentFile(ids: tombstones)

        let vectorsData = try VectorSegmentFile.encode(vectorsFile)
        let idsData = try IdSegmentFile.encode(idsFile)
        let payloadData = try PayloadSegmentFile.encode(payloadFile)
        let tombstonesData = try IdSegmentFile.encode(tombstonesFile)

        let vectorsCrc = try trailerCRC(of: vectorsData, label: "VECTORS.bin")
        let idsCrc = try trailerCRC(of: idsData, label: "IDS.bin")
        let payloadsCrc = try PayloadSegmentFile.trailerCRC(of: payloadData)
        let tombstonesCrc = try trailerCRC(of: tombstonesData, label: "TOMBSTONES.bin")

        try writeData(vectorsData, to: vectorsURL, label: "VECTORS.bin")
        try writeData(idsData, to: idsURL, label: "IDS.bin")
        try writeData(payloadData, to: payloadURL, label: "PAYLOAD.bin")
        try writeData(tombstonesData, to: tombstonesURL, label: "TOMBSTONES.bin")

        try fsyncFile(at: vectorsURL)
        try fsyncFile(at: idsURL)
        try fsyncFile(at: payloadURL)
        try fsyncFile(at: tombstonesURL)

        let meta = SegmentMetaDocument(
            segmentId: segmentId,
            dimension: dimension,
            rowCount: UInt64(rows.count),
            index: index,
            vectorsCrc32: vectorsCrc,
            idsCrc32: idsCrc,
            payloadsCrc32: payloadsCrc,
            tombstonesCrc32: tombstonesCrc
        )
        try JSONFileStore.writeAtomic(meta, to: metaURL)
        try fsyncFile(at: metaURL)

        return WriteResult(
            segmentId: segmentId,
            rowCount: UInt64(rows.count),
            vectorsCrc32: vectorsCrc,
            idsCrc32: idsCrc,
            payloadsCrc32: payloadsCrc,
            tombstonesCrc32: tombstonesCrc,
            meta: meta
        )
    }

    /// Loads a sealed segment directory into parallel row data after validating meta + CRCs.
    ///
    /// Missing `TOMBSTONES.bin` is allowed when `SEGMENT_META.tombstonesCrc32 == 0`
    /// (S15 segments). A non-zero meta CRC requires the file to be present and match.
    public static func loadSegment(
        segmentId: UInt64,
        expectedDimension: Int,
        vectorsURL: URL,
        idsURL: URL,
        payloadURL: URL,
        tombstonesURL: URL,
        metaURL: URL
    ) throws -> LoadResult {
        guard JSONFileStore.exists(metaURL) else {
            throw VectorSwiftError.corrupted(
                path: metaURL.path,
                reason: "Missing SEGMENT_META.json for segment \(segmentId)"
            )
        }
        let meta = try JSONFileStore.read(SegmentMetaDocument.self, from: metaURL)
        if meta.formatVersion != StorageFormat.version {
            throw VectorSwiftError.corrupted(
                path: metaURL.path,
                reason: "Unsupported SEGMENT_META formatVersion \(meta.formatVersion)"
            )
        }
        guard meta.segmentId == segmentId else {
            throw VectorSwiftError.corrupted(
                path: metaURL.path,
                reason: "SEGMENT_META segmentId \(meta.segmentId) != directory id \(segmentId)"
            )
        }
        guard meta.dimension == expectedDimension else {
            throw VectorSwiftError.corrupted(
                path: metaURL.path,
                reason: "SEGMENT_META dimension \(meta.dimension) != collection \(expectedDimension)"
            )
        }

        let vectorsFile = try VectorSegmentFile.read(from: vectorsURL)
        let idsFile = try IdSegmentFile.read(from: idsURL)
        let payloadFile = try PayloadSegmentFile.read(from: payloadURL)

        let vectorsData = try Data(contentsOf: vectorsURL)
        let idsData = try Data(contentsOf: idsURL)
        let payloadData = try Data(contentsOf: payloadURL)

        let vectorsCrc = try trailerCRC(of: vectorsData, label: "VECTORS.bin")
        let idsCrc = try trailerCRC(of: idsData, label: "IDS.bin")
        let payloadsCrc = try PayloadSegmentFile.trailerCRC(of: payloadData)

        guard vectorsCrc == meta.vectorsCrc32 else {
            throw VectorSwiftError.corrupted(
                path: vectorsURL.path,
                reason: "VECTORS.bin CRC does not match SEGMENT_META"
            )
        }
        guard idsCrc == meta.idsCrc32 else {
            throw VectorSwiftError.corrupted(
                path: idsURL.path,
                reason: "IDS.bin CRC does not match SEGMENT_META"
            )
        }
        guard payloadsCrc == meta.payloadsCrc32 else {
            throw VectorSwiftError.corrupted(
                path: payloadURL.path,
                reason: "PAYLOAD.bin CRC does not match SEGMENT_META"
            )
        }

        let rowCount = Int(meta.rowCount)
        guard vectorsFile.count == rowCount,
              idsFile.count == rowCount,
              payloadFile.count == rowCount
        else {
            throw VectorSwiftError.corrupted(
                path: metaURL.path,
                reason: "Segment row count mismatch meta=\(rowCount) vectors=\(vectorsFile.count) ids=\(idsFile.count) payloads=\(payloadFile.count)"
            )
        }
        guard vectorsFile.dimension == expectedDimension else {
            throw VectorSwiftError.corrupted(
                path: vectorsURL.path,
                reason: "VECTORS.bin dimension mismatch"
            )
        }

        let tombstones = try loadTombstones(
            tombstonesURL: tombstonesURL,
            expectedCrc: meta.tombstonesCrc32
        )

        var rows: [Row] = []
        rows.reserveCapacity(rowCount)
        let dim = expectedDimension
        for i in 0..<rowCount {
            let start = i * dim
            let vector = Array(vectorsFile.vectors[start..<(start + dim)])
            rows.append(
                Row(id: idsFile.ids[i], vector: vector, payload: payloadFile.payloads[i])
            )
        }
        return LoadResult(rows: rows, tombstones: tombstones, meta: meta)
    }

    // MARK: - Internals

    private static func loadTombstones(
        tombstonesURL: URL,
        expectedCrc: UInt32
    ) throws -> [PointID] {
        let exists = FileManager.default.fileExists(atPath: tombstonesURL.path)
        if !exists {
            if expectedCrc != 0 {
                throw VectorSwiftError.corrupted(
                    path: tombstonesURL.path,
                    reason: "Missing TOMBSTONES.bin but SEGMENT_META.tombstonesCrc32 is non-zero"
                )
            }
            return []
        }

        let file = try IdSegmentFile.read(from: tombstonesURL)
        let data = try Data(contentsOf: tombstonesURL)
        let crc = try trailerCRC(of: data, label: "TOMBSTONES.bin")
        if expectedCrc != 0, crc != expectedCrc {
            throw VectorSwiftError.corrupted(
                path: tombstonesURL.path,
                reason: "TOMBSTONES.bin CRC does not match SEGMENT_META"
            )
        }
        return file.ids
    }

    private static func trailerCRC(of data: Data, label: String) throws -> UInt32 {
        guard data.count >= 4 else {
            throw VectorSwiftError.corrupted(path: "", reason: "\(label) missing CRC")
        }
        var offset = data.count - 4
        return try BinaryIO.readUInt32(from: data, at: &offset)
    }

    private static func writeData(_ data: Data, to url: URL, label: String) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw VectorSwiftError.io("Failed to write \(label) at \(url.path): \(error)")
        }
    }

    private static func fsyncFile(at url: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to fsync \(url.path): \(error)")
        }
    }
}
