import VectorSwiftCore

/// In-memory collection of points. No disk I/O.
public actor Collection {
    public nonisolated let name: String

    private let collectionConfig: CollectionConfig
    private var live: [PointID: Entry] = [:]
    /// Number of successful deletes of previously live ids (for `count(includeTombstones:)`).
    private var tombstoneCount: Int = 0

    private struct Entry: Sendable {
        var vector: [Float]
        var payload: [String: PayloadValue]
    }

    /// Creates an empty in-memory collection.
    public init(config: CollectionConfig) throws {
        try VectorValidation.requireCollectionName(config.name)
        guard config.dimension >= 1 else {
            throw VectorSwiftError.invalidArgument(
                "Collection dimension must be >= 1, got \(config.dimension)"
            )
        }
        self.name = config.name
        self.collectionConfig = config
    }

    public var config: CollectionConfig {
        collectionConfig
    }

    /// Inserts or replaces points. Empty batch is a no-op.
    public func upsert(_ points: [Point]) throws {
        for point in points {
            try VectorValidation.requirePointID(point.id)
            try VectorValidation.requireDimension(point.vector, expected: collectionConfig.dimension)

            var vector = point.vector
            if collectionConfig.normalizeVectors {
                vector = try VectorValidation.normalized(vector)
            }

            live[point.id] = Entry(vector: vector, payload: point.payload)
        }
    }

    /// Deletes live points by id. Unknown ids are ignored.
    public func delete(ids: [PointID]) {
        for id in ids {
            if live.removeValue(forKey: id) != nil {
                tombstoneCount += 1
            }
        }
    }

    /// Returns live points for the given ids (missing ids omitted).
    ///
    /// Order follows `ids`. When `withVector` is false, returned vectors are empty arrays.
    public func get(ids: [PointID], withVector: Bool = false) -> [Point] {
        var result: [Point] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            guard let entry = live[id] else { continue }
            result.append(
                Point(
                    id: id,
                    vector: withVector ? entry.vector : [],
                    payload: entry.payload
                )
            )
        }
        return result
    }

    /// Live point count, or live + tombstones when `includeTombstones` is true.
    public func count(includeTombstones: Bool = false) -> Int {
        if includeTombstones {
            return live.count + tombstoneCount
        }
        return live.count
    }

    /// No-op for the in-memory engine.
    public func checkpoint() {}

    // MARK: - Internals for search (S07)

    /// Snapshot of live rows for indexing. Order is unspecified but stable for a given snapshot.
    func liveSnapshot() -> (ids: [PointID], vectors: [[Float]], payloads: [[String: PayloadValue]]) {
        var ids: [PointID] = []
        var vectors: [[Float]] = []
        var payloads: [[String: PayloadValue]] = []
        ids.reserveCapacity(live.count)
        vectors.reserveCapacity(live.count)
        payloads.reserveCapacity(live.count)
        for (id, entry) in live {
            ids.append(id)
            vectors.append(entry.vector)
            payloads.append(entry.payload)
        }
        return (ids, vectors, payloads)
    }
}
