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
    /// Next segment id to allocate when sealing (reserved for segment storage).
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
