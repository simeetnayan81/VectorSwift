import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftIndex

/// In-memory collection of points. No disk I/O.
public actor Collection {
    public nonisolated let name: String

    private let collectionConfig: CollectionConfig
    private let compute: any VectorCompute
    private var live: [PointID: Entry] = [:]
    /// Number of successful deletes of previously live ids (for `count(includeTombstones:)`).
    private var tombstoneCount: Int = 0

    private struct Entry: Sendable {
        var vector: [Float]
        var payload: [String: PayloadValue]
    }

    /// Creates an empty in-memory collection.
    ///
    /// - Parameter compute: Distance backend used by search (default: portable CPU).
    public init(
        config: CollectionConfig,
        compute: any VectorCompute = PortableCPUCompute()
    ) throws {
        try VectorValidation.requireCollectionName(config.name)
        guard config.dimension >= 1 else {
            throw VectorSwiftError.invalidArgument(
                "Collection dimension must be >= 1, got \(config.dimension)"
            )
        }
        self.name = config.name
        self.collectionConfig = config
        self.compute = compute
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

    /// Exact nearest-neighbor search over all live points (flat index).
    ///
    /// Results are ordered by nondecreasing `distance` (smaller = closer).
    /// `SearchRequest.filter` is ignored until filtered search is implemented.
    /// `SearchRequest.ef` is ignored for flat search.
    public func search(_ request: SearchRequest) throws -> [ScoredPoint] {
        try VectorValidation.requireDimension(
            request.vector,
            expected: collectionConfig.dimension
        )
        guard request.k >= 1 else {
            throw VectorSwiftError.invalidArgument("k must be >= 1, got \(request.k)")
        }

        if live.isEmpty {
            return []
        }

        var query = request.vector
        if collectionConfig.normalizeVectors {
            query = try VectorValidation.normalized(query)
        }

        let snapshot = liveSnapshot()
        let count = snapshot.ids.count
        let dim = collectionConfig.dimension

        // Row-major matrix: row i is snapshot.vectors[i]
        var matrix = [Float]()
        matrix.reserveCapacity(count * dim)
        for vector in snapshot.vectors {
            matrix.append(contentsOf: vector)
        }

        let hits = try matrix.withUnsafeBufferPointer { buffer in
            try FlatIndex.search(
                query: query,
                database: buffer,
                count: count,
                dim: dim,
                k: request.k,
                metric: collectionConfig.metric,
                compute: compute
            )
        }

        return hits.map { hit in
            let i = Int(hit.row)
            return ScoredPoint(
                id: snapshot.ids[i],
                distance: hit.distance,
                payload: request.withPayload ? snapshot.payloads[i] : nil,
                vector: request.withVector ? snapshot.vectors[i] : nil
            )
        }
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

    // MARK: - Internals

    /// Snapshot of live rows. Dictionary iteration order is used as row order for this search.
    private func liveSnapshot() -> (
        ids: [PointID],
        vectors: [[Float]],
        payloads: [[String: PayloadValue]]
    ) {
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
