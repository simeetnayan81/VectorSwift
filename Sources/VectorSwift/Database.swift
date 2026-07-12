import Foundation
import VectorSwiftCore
import VectorSwiftCompute

/// Multi-collection database handle.
///
/// ## Responsibilities
/// - Own a catalog of named ``Collection`` instances.
/// - Apply database-wide settings (`DatabaseConfig`), including which distance
///   backend newly created collections receive.
/// - Provide lifecycle operations: open, create/drop/list collections, checkpoint, close.
///
/// ## Persistence
/// Vector data lives in memory for now. `open(path:)` may create a directory when
/// a path is provided so applications can reserve a location, but collection
/// contents are **not** loaded from or written to disk. Closing the database
/// drops the in-memory catalog.
///
/// ## Concurrency
/// `Database` is an actor. Catalog mutations are serialized here; point-level
/// work runs on each collection's own actor after `collection(name:)` returns.
public actor Database {
    private let databaseConfig: DatabaseConfig
    private let compute: any VectorCompute
    /// Optional directory associated with this instance (not used for load/save yet).
    private let path: URL?
    private var collections: [String: Collection] = [:]
    private var isClosed = false

    private init(
        path: URL?,
        config: DatabaseConfig,
        compute: any VectorCompute
    ) {
        self.path = path
        self.databaseConfig = config
        self.compute = compute
    }

    /// Opens a database.
    ///
    /// - Parameters:
    ///   - path: Optional working directory. When non-nil, the directory is created
    ///     if needed. Data is still held only in memory.
    ///   - config: Database-wide settings (compute preference, durability knobs for
    ///     future on-disk use, segment size hints).
    /// - Throws: `VectorSwiftError.backendUnavailable` if the requested compute
    ///   backend is not available; file-system errors if directory creation fails.
    public static func open(
        path: URL? = nil,
        config: DatabaseConfig = .default
    ) async throws -> Database {
        let compute = try makeCompute(preference: config.compute)
        if let path {
            try FileManager.default.createDirectory(
                at: path,
                withIntermediateDirectories: true
            )
        }
        return Database(path: path, config: config, compute: compute)
    }

    /// Configuration passed to `open`.
    public var config: DatabaseConfig {
        databaseConfig
    }

    /// Filesystem root if one was provided to `open`; otherwise `nil`.
    public var storagePath: URL? {
        path
    }

    /// Creates a new empty collection and registers it in the catalog.
    ///
    /// - Throws: `collectionExists` if the name is taken; validation errors from
    ///   `Collection` (bad name/dimension, unsupported index type); `closed` if
    ///   the database has been closed.
    public func createCollection(_ config: CollectionConfig) throws {
        try ensureOpen()
        if collections[config.name] != nil {
            throw VectorSwiftError.collectionExists(config.name)
        }
        let collection = try Collection(config: config, compute: compute)
        collections[config.name] = collection
    }

    /// Removes a collection from the catalog.
    ///
    /// Existing handles obtained earlier are not invalidated automatically; prefer
    /// dropping only when no concurrent work uses that collection.
    ///
    /// - Throws: `collectionNotFound` or `closed`.
    public func dropCollection(name: String) throws {
        try ensureOpen()
        guard collections.removeValue(forKey: name) != nil else {
            throw VectorSwiftError.collectionNotFound(name)
        }
    }

    /// Returns registered collection names in sorted order.
    public func listCollections() throws -> [String] {
        try ensureOpen()
        return collections.keys.sorted()
    }

    /// Returns the actor handle for a registered collection.
    ///
    /// The same instance is returned for a given name until it is dropped.
    ///
    /// - Throws: `collectionNotFound` or `closed`.
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
    /// After a successful close, catalog operations throw `VectorSwiftError.closed`.
    /// Calling `close` again also throws `closed`.
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

    /// Resolves a distance backend from configuration.
    ///
    /// `.cpu` and `.auto` currently both select portable CPU. `.mlx` fails until
    /// an MLX-backed implementation is linked and registered here.
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
}
