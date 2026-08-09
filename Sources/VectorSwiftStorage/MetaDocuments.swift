import Foundation
import VectorSwiftCore

/// Current on-disk JSON schema version for meta files.
public enum StorageFormat {
    public static let version: Int = 1
}

/// Root database metadata written to `DB_META.json`.
public struct DatabaseMetaDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var config: DatabaseConfig

    public init(formatVersion: Int = StorageFormat.version, config: DatabaseConfig) {
        self.formatVersion = formatVersion
        self.config = config
    }
}

/// Catalog of collection names → relative directory under the DB root.
public struct CatalogDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    /// Map of collection name to relative path (e.g. `collections/docs`).
    public var collections: [String: String]

    public init(
        formatVersion: Int = StorageFormat.version,
        collections: [String: String] = [:]
    ) {
        self.formatVersion = formatVersion
        self.collections = collections
    }
}

/// Per-collection metadata written to `COLL_META.json`.
public struct CollectionMetaDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var config: CollectionConfig
    /// Next segment id to allocate when sealing.
    public var nextSegmentId: UInt64
    /// Next internal row id (reserved for segment storage).
    public var nextRowId: UInt64

    public init(
        formatVersion: Int = StorageFormat.version,
        config: CollectionConfig,
        nextSegmentId: UInt64 = 1,
        nextRowId: UInt64 = 1
    ) {
        self.formatVersion = formatVersion
        self.config = config
        self.nextSegmentId = nextSegmentId
        self.nextRowId = nextRowId
    }
}

/// Live sealed segment list for a collection (`MANIFEST.json`).
///
/// Published via write-tmp + fsync + rename-over (see `JSONFileStore.writeAtomic`).
/// Readers trust only the final file. Segment ids are in seal order (oldest first).
public struct ManifestDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    /// Monotonic generation; incremented on every successful seal publish.
    public var generation: UInt64
    /// Active sealed segment ids in seal order (oldest first; later ids win on conflict).
    public var segmentIds: [UInt64]
    /// WAL epoch (bumped when the log is reclaimed after seal).
    public var walEpoch: UInt64

    public init(
        formatVersion: Int = StorageFormat.version,
        generation: UInt64 = 0,
        segmentIds: [UInt64] = [],
        walEpoch: UInt64 = 0
    ) {
        self.formatVersion = formatVersion
        self.generation = generation
        self.segmentIds = segmentIds
        self.walEpoch = walEpoch
    }

    public static let empty = ManifestDocument()
}

/// Per-sealed-segment metadata (`SEGMENT_META.json`).
///
/// Written last in the segment directory so incomplete seals are detectable.
public struct SegmentMetaDocument: Equatable, Sendable {
    public var formatVersion: Int
    public var segmentId: UInt64
    public var dimension: Int
    public var rowCount: UInt64
    public var index: IndexConfig
    public var vectorsCrc32: UInt32
    public var idsCrc32: UInt32
    public var payloadsCrc32: UInt32
    /// CRC of `TOMBSTONES.bin` trailer. `0` means “file missing is OK” (S15 segments).
    public var tombstonesCrc32: UInt32

    public init(
        formatVersion: Int = StorageFormat.version,
        segmentId: UInt64,
        dimension: Int,
        rowCount: UInt64,
        index: IndexConfig = .flat,
        vectorsCrc32: UInt32,
        idsCrc32: UInt32,
        payloadsCrc32: UInt32,
        tombstonesCrc32: UInt32 = 0
    ) {
        self.formatVersion = formatVersion
        self.segmentId = segmentId
        self.dimension = dimension
        self.rowCount = rowCount
        self.index = index
        self.vectorsCrc32 = vectorsCrc32
        self.idsCrc32 = idsCrc32
        self.payloadsCrc32 = payloadsCrc32
        self.tombstonesCrc32 = tombstonesCrc32
    }
}

extension SegmentMetaDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case formatVersion
        case segmentId
        case dimension
        case rowCount
        case index
        case vectorsCrc32
        case idsCrc32
        case payloadsCrc32
        case tombstonesCrc32
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        segmentId = try c.decode(UInt64.self, forKey: .segmentId)
        dimension = try c.decode(Int.self, forKey: .dimension)
        rowCount = try c.decode(UInt64.self, forKey: .rowCount)
        index = try c.decode(IndexConfig.self, forKey: .index)
        vectorsCrc32 = try c.decode(UInt32.self, forKey: .vectorsCrc32)
        idsCrc32 = try c.decode(UInt32.self, forKey: .idsCrc32)
        payloadsCrc32 = try c.decode(UInt32.self, forKey: .payloadsCrc32)
        tombstonesCrc32 = try c.decodeIfPresent(UInt32.self, forKey: .tombstonesCrc32) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(segmentId, forKey: .segmentId)
        try c.encode(dimension, forKey: .dimension)
        try c.encode(rowCount, forKey: .rowCount)
        try c.encode(index, forKey: .index)
        try c.encode(vectorsCrc32, forKey: .vectorsCrc32)
        try c.encode(idsCrc32, forKey: .idsCrc32)
        try c.encode(payloadsCrc32, forKey: .payloadsCrc32)
        try c.encode(tombstonesCrc32, forKey: .tombstonesCrc32)
    }
}
