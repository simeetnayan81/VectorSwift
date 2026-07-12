import Foundation

/// On-disk path layout for a database root directory.
///
/// ```
/// {root}/
///   DB_META.json
///   CATALOG.json
///   collections/{name}/COLL_META.json
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
}
