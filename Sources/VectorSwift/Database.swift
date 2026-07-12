import Foundation
import VectorSwiftCore
import VectorSwiftCompute

/// Multi-collection catalog. In-memory only; path is reserved for durable storage later.
public actor Database {
    private let databaseConfig: DatabaseConfig
    private let compute: any VectorCompute
    /// Optional on-disk root; not used for load/save until durability stories.
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

    /// Opens an in-memory database.
    ///
    /// - Parameters:
    ///   - path: Optional directory. When non-`nil`, the directory is created if needed.
    ///     Data is not loaded from or written to disk yet.
    ///   - config: Database-wide settings (compute preference, durability placeholders).
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

    public var config: DatabaseConfig {
        databaseConfig
    }

    /// Filesystem root if one was provided to `open`.
    public var storagePath: URL? {
        path
    }

    /// Creates a new empty collection.
    public func createCollection(_ config: CollectionConfig) throws {
        try ensureOpen()
        if collections[config.name] != nil {
            throw VectorSwiftError.collectionExists(config.name)
        }
        let collection = try Collection(config: config, compute: compute)
        collections[config.name] = collection
    }

    /// Removes a collection from the catalog.
    public func dropCollection(name: String) throws {
        try ensureOpen()
        guard collections.removeValue(forKey: name) != nil else {
            throw VectorSwiftError.collectionNotFound(name)
        }
    }

    /// Sorted collection names.
    public func listCollections() throws -> [String] {
        try ensureOpen()
        return collections.keys.sorted()
    }

    /// Returns an existing collection handle.
    public func collection(name: String) throws -> Collection {
        try ensureOpen()
        guard let collection = collections[name] else {
            throw VectorSwiftError.collectionNotFound(name)
        }
        return collection
    }

    /// Checkpoints every collection (no-op while in-memory only).
    public func checkpoint() async throws {
        try ensureOpen()
        for collection in collections.values {
            await collection.checkpoint()
        }
    }

    /// Closes the database. Further catalog operations throw `closed`.
    ///
    /// - Throws: `VectorSwiftError.closed` if already closed.
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
}
