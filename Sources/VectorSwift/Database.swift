import Foundation
import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftStorage

/// Multi-collection database handle.
///
/// ## Responsibilities
/// - Own a catalog of named `Collection` instances.
/// - Apply database-wide settings (`DatabaseConfig`), including which distance
///   backend newly created collections receive.
/// - Provide lifecycle operations: open, create/drop/list collections, checkpoint, close.
///
/// ## Persistence modes
/// - **No path** (`open()`): purely in-memory. Closing drops the catalog; nothing on disk.
/// - **With path** (`open(path:)`): writes and reloads catalog metadata under that directory
///   (`DB_META.json`, `CATALOG.json`, `collections/*/COLL_META.json`). Collection **points**
///   are still held only in memory until segment/WAL storage is implemented; reopening
///   restores collection definitions (empty of vectors).
///
/// ## Concurrency
/// `Database` is an actor. Catalog mutations are serialized here; point-level
/// work runs on each collection's own actor after `collection(name:)` returns.
public actor Database {
    private let databaseConfig: DatabaseConfig
    private let compute: any VectorCompute
    private let layout: DatabaseLayout?
    private var collections: [String: Collection] = [:]
    private var isClosed = false

    private init(
        layout: DatabaseLayout?,
        config: DatabaseConfig,
        compute: any VectorCompute,
        collections: [String: Collection]
    ) {
        self.layout = layout
        self.databaseConfig = config
        self.compute = compute
        self.collections = collections
    }

    /// Opens a database.
    ///
    /// - Parameters:
    ///   - path: Optional working directory. When set, meta files are created/loaded there.
    ///   - config: Used for a **new** on-disk database, or for pure in-memory mode.
    ///     If `path` already contains `DB_META.json`, the on-disk config is used instead.
    /// - Throws: `backendUnavailable`, `corrupted` for invalid meta JSON, or I/O errors.
    public static func open(
        path: URL? = nil,
        config: DatabaseConfig = .default
    ) async throws -> Database {
        let compute = try makeCompute(preference: config.compute)

        guard let path else {
            return Database(
                layout: nil,
                config: config,
                compute: compute,
                collections: [:]
            )
        }

        let layout = DatabaseLayout(root: path)
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.collectionsDirectory,
            withIntermediateDirectories: true
        )

        let resolvedConfig: DatabaseConfig
        if JSONFileStore.exists(layout.dbMeta) {
            let meta = try JSONFileStore.read(DatabaseMetaDocument.self, from: layout.dbMeta)
            try validateFormatVersion(meta.formatVersion, path: layout.dbMeta)
            resolvedConfig = meta.config
            // Re-resolve compute from on-disk config (open() may have passed defaults).
            let diskCompute = try makeCompute(preference: resolvedConfig.compute)
            let loaded = try loadCollections(layout: layout, compute: diskCompute)
            return Database(
                layout: layout,
                config: resolvedConfig,
                compute: diskCompute,
                collections: loaded
            )
        } else {
            resolvedConfig = config
            let meta = DatabaseMetaDocument(config: resolvedConfig)
            try JSONFileStore.writeAtomic(meta, to: layout.dbMeta)
            try JSONFileStore.writeAtomic(CatalogDocument(), to: layout.catalog)
            return Database(
                layout: layout,
                config: resolvedConfig,
                compute: compute,
                collections: [:]
            )
        }
    }

    /// Configuration in effect (from open args or loaded `DB_META.json`).
    public var config: DatabaseConfig {
        databaseConfig
    }

    /// Filesystem root when opened with a path; otherwise `nil`.
    public var storagePath: URL? {
        layout?.root
    }

    /// Creates a new empty collection and registers it in the catalog.
    ///
    /// With an on-disk root, also writes `COLL_META.json` and updates `CATALOG.json`.
    public func createCollection(_ config: CollectionConfig) throws {
        try ensureOpen()
        if collections[config.name] != nil {
            throw VectorSwiftError.collectionExists(config.name)
        }
        let collection = try Collection(config: config, compute: compute)
        collections[config.name] = collection

        if let layout {
            try persistNewCollection(config: config, layout: layout)
        }
    }

    /// Removes a collection from the catalog.
    ///
    /// With an on-disk root, updates `CATALOG.json` and deletes the collection directory.
    public func dropCollection(name: String) throws {
        try ensureOpen()
        guard collections.removeValue(forKey: name) != nil else {
            throw VectorSwiftError.collectionNotFound(name)
        }

        if let layout {
            try persistDropCollection(name: name, layout: layout)
        }
    }

    /// Returns registered collection names in sorted order.
    public func listCollections() throws -> [String] {
        try ensureOpen()
        return collections.keys.sorted()
    }

    /// Returns the actor handle for a registered collection.
    public func collection(name: String) throws -> Collection {
        try ensureOpen()
        guard let collection = collections[name] else {
            throw VectorSwiftError.collectionNotFound(name)
        }
        return collection
    }

    /// Invokes `checkpoint` on every collection currently in the catalog.
    public func checkpoint() async throws {
        try ensureOpen()
        for collection in collections.values {
            await collection.checkpoint()
        }
    }

    /// Closes the database and clears the in-memory catalog.
    ///
    /// On-disk meta files (if any) remain on disk for a later `open(path:)`.
    /// Calling `close` again throws `closed`.
    public func close() throws {
        if isClosed {
            throw VectorSwiftError.closed
        }
        isClosed = true
        collections.removeAll()
    }

    // MARK: - Internals

    private func ensureOpen() throws {
        if isClosed {
            throw VectorSwiftError.closed
        }
    }

    private static func makeCompute(
        preference: ComputeBackendPreference
    ) throws -> any VectorCompute {
        switch preference {
        case .cpu, .auto:
            return PortableCPUCompute()
        case .mlx:
            throw VectorSwiftError.backendUnavailable("mlx")
        }
    }

    private static func validateFormatVersion(_ version: Int, path: URL) throws {
        if version != StorageFormat.version {
            throw VectorSwiftError.corrupted(
                path: path.path,
                reason: "Unsupported formatVersion \(version); expected \(StorageFormat.version)"
            )
        }
    }

    private static func loadCollections(
        layout: DatabaseLayout,
        compute: any VectorCompute
    ) throws -> [String: Collection] {
        guard JSONFileStore.exists(layout.catalog) else {
            throw VectorSwiftError.corrupted(
                path: layout.catalog.path,
                reason: "Missing CATALOG.json next to DB_META.json"
            )
        }
        let catalog = try JSONFileStore.read(CatalogDocument.self, from: layout.catalog)
        try validateFormatVersion(catalog.formatVersion, path: layout.catalog)

        var result: [String: Collection] = [:]
        for (name, _) in catalog.collections {
            let metaURL = layout.collectionMeta(name: name)
            guard JSONFileStore.exists(metaURL) else {
                throw VectorSwiftError.corrupted(
                    path: metaURL.path,
                    reason: "Catalog references collection '\(name)' but COLL_META.json is missing"
                )
            }
            let meta = try JSONFileStore.read(CollectionMetaDocument.self, from: metaURL)
            try validateFormatVersion(meta.formatVersion, path: metaURL)
            guard meta.config.name == name else {
                throw VectorSwiftError.corrupted(
                    path: metaURL.path,
                    reason: "Collection name mismatch: catalog '\(name)' vs meta '\(meta.config.name)'"
                )
            }
            let collection = try Collection(config: meta.config, compute: compute)
            result[name] = collection
        }
        return result
    }

    private func persistNewCollection(config: CollectionConfig, layout: DatabaseLayout) throws {
        let dir = layout.collectionDirectory(name: config.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let collMeta = CollectionMetaDocument(config: config)
        try JSONFileStore.writeAtomic(collMeta, to: layout.collectionMeta(name: config.name))

        var catalog: CatalogDocument
        if JSONFileStore.exists(layout.catalog) {
            catalog = try JSONFileStore.read(CatalogDocument.self, from: layout.catalog)
            try Self.validateFormatVersion(catalog.formatVersion, path: layout.catalog)
        } else {
            catalog = CatalogDocument()
        }
        catalog.collections[config.name] = "collections/\(config.name)"
        try JSONFileStore.writeAtomic(catalog, to: layout.catalog)
    }

    private func persistDropCollection(name: String, layout: DatabaseLayout) throws {
        var catalog: CatalogDocument
        if JSONFileStore.exists(layout.catalog) {
            catalog = try JSONFileStore.read(CatalogDocument.self, from: layout.catalog)
            try Self.validateFormatVersion(catalog.formatVersion, path: layout.catalog)
        } else {
            catalog = CatalogDocument()
        }
        catalog.collections.removeValue(forKey: name)
        try JSONFileStore.writeAtomic(catalog, to: layout.catalog)

        let dir = layout.collectionDirectory(name: name)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
