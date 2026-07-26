import Foundation

/// On-disk path layout for a database root directory.
///
/// ```
/// {root}/
///   DB_META.json
///   CATALOG.json
///   collections/{name}/
///     COLL_META.json
///     wal/wal.log
///     segments/{segmentId}/
///       VECTORS.bin
///       IDS.bin
/// ```
public struct DatabaseLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var dbMeta: URL {
        root.appendingPathComponent("DB_META.json", isDirectory: false)
    }

    public var catalog: URL {
        root.appendingPathComponent("CATALOG.json", isDirectory: false)
    }

    public var collectionsDirectory: URL {
        root.appendingPathComponent("collections", isDirectory: true)
    }

    public func collectionDirectory(name: String) -> URL {
        collectionsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    public func collectionMeta(name: String) -> URL {
        collectionDirectory(name: name)
            .appendingPathComponent("COLL_META.json", isDirectory: false)
    }

    public func walDirectory(collection: String) -> URL {
        collectionDirectory(name: collection)
            .appendingPathComponent("wal", isDirectory: true)
    }

    public func walLog(collection: String) -> URL {
        walDirectory(collection: collection)
            .appendingPathComponent("wal.log", isDirectory: false)
    }

    public func segmentsDirectory(collection: String) -> URL {
        collectionDirectory(name: collection)
            .appendingPathComponent("segments", isDirectory: true)
    }

    public func segmentDirectory(collection: String, segmentId: UInt64) -> URL {
        segmentsDirectory(collection: collection)
            .appendingPathComponent(String(segmentId), isDirectory: true)
    }

    public func vectorsBin(collection: String, segmentId: UInt64) -> URL {
        segmentDirectory(collection: collection, segmentId: segmentId)
            .appendingPathComponent("VECTORS.bin", isDirectory: false)
    }

    public func idsBin(collection: String, segmentId: UInt64) -> URL {
        segmentDirectory(collection: collection, segmentId: segmentId)
            .appendingPathComponent("IDS.bin", isDirectory: false)
    }
}
