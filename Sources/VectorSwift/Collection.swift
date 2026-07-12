import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftIndex

/// Named set of points with fixed dimensionality and distance metric.
///
/// ## Storage model
/// Live points are held in an in-memory dictionary keyed by public `PointID`.
/// There is no segment file or WAL yet: process exit discards contents.
///
/// ## Concurrency
/// `Collection` is an actor. All mutations and searches are serialized on that
/// actor, so callers can safely share one collection across tasks.
///
/// ## Search path
/// `search` snapshots live points into a row-major float matrix, runs exact
/// `FlatIndex` search via the injected `VectorCompute` backend, then maps row
/// indices back to public IDs and optional payload/vector fields.
///
/// ## Normalization
/// When `config.normalizeVectors` is true, vectors are L2-normalized on upsert
/// and the query is normalized on search (zero vectors are rejected). This is
/// the usual setup for cosine similarity.
public actor Collection {
    /// Collection name (immutable; matches `config.name`).
    public nonisolated let name: String

    private let collectionConfig: CollectionConfig
    private let compute: any VectorCompute
    private var live: [PointID: Entry] = [:]
    /// Count of deletes that removed a live id (for `count(includeTombstones:)`).
    private var tombstoneCount: Int = 0

    private struct Entry: Sendable {
        var vector: [Float]
        var payload: [String: PayloadValue]
    }

    /// Creates an empty collection.
    ///
    /// - Parameters:
    ///   - config: Dimension, metric, index type, and related options. Dimension
    ///     and metric are fixed for the lifetime of the collection.
    ///   - compute: Batch distance backend used by search. Defaults to portable CPU.
    /// - Throws: Validation errors for name/dimension, or if `config.index` is not
    ///   `.flat` (only exact flat search is implemented).
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
        guard config.index == .flat else {
            throw VectorSwiftError.invalidArgument(
                "Unsupported index \(config.index.rawValue); only 'flat' is available"
            )
        }
        self.name = config.name
        self.collectionConfig = config
        self.compute = compute
    }

    /// Configuration captured at creation time.
    public var config: CollectionConfig {
        collectionConfig
    }

    /// Inserts or replaces points.
    ///
    /// Empty batches are ignored. Each point must use a non-empty id within the
    /// UTF-8 length limit and a vector of length `config.dimension`. Same-id
    /// upsert overwrites vector and payload in place.
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

    /// Removes live points by id. Unknown ids are ignored.
    ///
    /// Each successful removal increments the tombstone counter used by
    /// `count(includeTombstones: true)`.
    public func delete(ids: [PointID]) {
        for id in ids {
            if live.removeValue(forKey: id) != nil {
                tombstoneCount += 1
            }
        }
    }

    /// Fetches live points by id.
    ///
    /// Order matches `ids`. Missing ids are omitted. When `withVector` is false,
    /// returned points use an empty `vector` array (payload is still included).
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

    /// Exact nearest-neighbor search over all live points.
    ///
    /// Results are ordered by nondecreasing `distance` (smaller = closer under the
    /// collection metric). If fewer than `k` live points exist, all are returned.
    ///
    /// `SearchRequest.filter` is not evaluated (metadata filtering is not wired).
    /// `SearchRequest.ef` is ignored for flat search.
    ///
    /// - Throws: Dimension mismatch, invalid `k`, zero query when normalization is
    ///   required, or errors from the distance backend.
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

        // Pack into one contiguous row-major matrix for FlatIndex / VectorCompute.
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

    /// Number of live points, or live + tombstone count when requested.
    public func count(includeTombstones: Bool = false) -> Int {
        if includeTombstones {
            return live.count + tombstoneCount
        }
        return live.count
    }

    /// Flushes durable state when persistence is enabled.
    ///
    /// Currently a no-op because this collection is purely in-memory.
    public func checkpoint() {}

    // MARK: - Internals

    /// Copies live dictionary entries into parallel arrays for indexing.
    ///
    /// Row `i` in the packed matrix corresponds to `ids[i]`, `vectors[i]`, and
    /// `payloads[i]`. Iteration order is the dictionary's current order; it is
    /// stable for a single snapshot but not a public ordering guarantee.
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
