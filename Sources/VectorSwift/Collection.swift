import Foundation
import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftIndex
import VectorSwiftStorage

/// Named set of points with fixed dimensionality and distance metric.
///
/// ## Storage model
/// Live points are held in an in-memory dictionary keyed by public `PointID`.
/// When opened with a write-ahead log (path-backed database), mutations append
/// WAL records before updating memory so acked writes can be restored on reopen.
/// Sealed snapshots materialize the full live set into segment files under
/// `segments/{id}/`; after seal the WAL is reclaimed and reopen loads segments
/// then replays any post-seal WAL frames.
///
/// ## Durability (S14)
/// `DurabilityLevel` selects when the process waits for WAL data to reach stable
/// storage via `FileHandle.synchronize()`. All path-backed levels write WAL
/// frames before applying memory. See ``DurabilityLevel`` for loss windows.
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
/// the usual setup for cosine similarity. WAL stores post-normalization floats.
public actor Collection {
    /// Collection name (immutable; matches `config.name`).
    public nonisolated let name: String

    private let collectionConfig: CollectionConfig
    private let compute: any VectorCompute
    private let durability: DurabilityLevel
    private let wal: WriteAheadLog?
    private let balancedPolicy: BalancedDurabilityPolicy
    private let layout: DatabaseLayout?
    private let mutableSegmentMaxPoints: Int
    private let mutableSegmentMaxBytes: Int

    private var live: [PointID: Entry] = [:]
    /// Count of deletes that removed a live id (for `count(includeTombstones:)`).
    private var tombstoneCount: Int = 0
    /// Next segment id to allocate (persisted in `COLL_META.json`).
    private var nextSegmentId: UInt64
    /// True when live has changed since the last successful seal (or open).
    private var hasUnsealedData: Bool = false
    /// Approximate mutable size for seal thresholds (ops / vector bytes since seal).
    private var unsealedPointCount: Int = 0
    private var unsealedByteCount: Int = 0

    // MARK: Durability state (S14)

    private var pendingRecordCount: Int = 0
    private var pendingByteCount: Int = 0
    private var hasPendingSync: Bool = false
    private var flushTask: Task<Void, Never>?
    private var stickySyncError: VectorSwiftError?
    private var acceptingMutations: Bool = true

    private struct Entry: Sendable {
        var vector: [Float]
        var payload: [String: PayloadValue]
    }

    /// Creates an empty collection, optionally loading sealed segments and replaying a WAL.
    ///
    /// - Parameters:
    ///   - config: Dimension, metric, index type, and related options. Dimension
    ///     and metric are fixed for the lifetime of the collection.
    ///   - compute: Batch distance backend used by search. Defaults to portable CPU.
    ///   - durability: fsync policy for WAL-backed collections (see ``DurabilityLevel``).
    ///   - wal: When non-nil, existing records are replayed into memory and future
    ///     mutations are appended to this log.
    ///   - balancedPolicy: Group-fsync thresholds for ``DurabilityLevel/balanced``.
    ///     Production uses the default; tests inject tighter values.
    ///   - layout: Database root layout for segment/MANIFEST paths (path-backed).
    ///   - mutableSegmentMaxPoints: Seal when unsealed point ops reach this count.
    ///   - mutableSegmentMaxBytes: Seal when unsealed vector bytes reach this size.
    ///   - nextSegmentId: Next id to allocate (from `COLL_META.json`).
    /// - Throws: Validation errors for name/dimension, unsupported index, WAL I/O,
    ///   or corruption during segment load / replay.
    public init(
        config: CollectionConfig,
        compute: any VectorCompute = PortableCPUCompute(),
        durability: DurabilityLevel = .balanced,
        wal: WriteAheadLog? = nil,
        balancedPolicy: BalancedDurabilityPolicy = .default,
        layout: DatabaseLayout? = nil,
        mutableSegmentMaxPoints: Int = 10_000,
        mutableSegmentMaxBytes: Int = 64 * 1024 * 1024,
        nextSegmentId: UInt64 = 1
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
        guard mutableSegmentMaxPoints >= 1 else {
            throw VectorSwiftError.invalidArgument("mutableSegmentMaxPoints must be >= 1")
        }
        guard mutableSegmentMaxBytes >= 1 else {
            throw VectorSwiftError.invalidArgument("mutableSegmentMaxBytes must be >= 1")
        }
        self.name = config.name
        self.collectionConfig = config
        self.compute = compute
        self.durability = durability
        self.wal = wal
        self.balancedPolicy = balancedPolicy
        self.layout = layout
        self.mutableSegmentMaxPoints = mutableSegmentMaxPoints
        self.mutableSegmentMaxBytes = mutableSegmentMaxBytes
        self.nextSegmentId = nextSegmentId

        // Base: sealed segments from MANIFEST (full snapshot model).
        if let layout {
            try Self.loadSealedIntoLive(
                layout: layout,
                collectionName: config.name,
                dimension: config.dimension,
                live: &live
            )
        }

        // Redo: post-seal (or pre-first-seal) WAL frames.
        if let wal {
            let records = try wal.readAllValidRecords(truncateIncompleteTail: true)
            for record in records {
                try Self.applyRecord(
                    record,
                    into: &live,
                    tombstoneCount: &tombstoneCount,
                    expectedDimension: config.dimension,
                    validateDimension: true
                )
            }
            // If WAL still has upsert/delete frames, treat state as unsealed until next seal.
            if records.contains(where: {
                switch $0 {
                case .upsert, .delete: return true
                default: return false
                }
            }) {
                hasUnsealedData = true
                unsealedPointCount = live.count
                unsealedByteCount = live.values.reduce(0) { $0 + $1.vector.count * 4 }
            }
        }
    }

    /// Configuration captured at creation time.
    public var config: CollectionConfig {
        collectionConfig
    }

    /// Durability level for this collection's WAL policy.
    public var durabilityLevel: DurabilityLevel {
        durability
    }

    /// Inserts or replaces points.
    ///
    /// Empty batches are ignored. Each point must use a non-empty id within the
    /// UTF-8 length limit and a vector of length `config.dimension`. Same-id
    /// upsert overwrites vector and payload in place.
    ///
    /// With a WAL, records are written (and fsynced per ``DurabilityLevel``)
    /// before memory is updated, so a successful return is recoverable under the
    /// level's durability guarantees.
    public func upsert(_ points: [Point]) throws {
        guard !points.isEmpty else { return }
        try ensureAcceptingMutations()
        try throwIfStickyUnrecoverable()

        // Validate and materialize stored vectors first so we never write partial junk.
        var prepared: [(id: PointID, vector: [Float], payload: [String: PayloadValue])] = []
        prepared.reserveCapacity(points.count)
        for point in points {
            try VectorValidation.requirePointID(point.id)
            try VectorValidation.requireDimension(point.vector, expected: collectionConfig.dimension)

            var vector = point.vector
            if collectionConfig.normalizeVectors {
                vector = try VectorValidation.normalized(vector)
            }
            prepared.append((point.id, vector, point.payload))
        }

        if let wal {
            let records = prepared.map { item in
                WALRecord.upsert(id: item.id, vector: item.vector, payload: item.payload)
            }
            try appendRecords(records, using: wal)
        }

        for item in prepared {
            live[item.id] = Entry(vector: item.vector, payload: item.payload)
        }
        noteUnsealedMutation(pointCount: prepared.count, vectorBytes: prepared.reduce(0) {
            $0 + $1.vector.count * MemoryLayout<Float>.size
        })
        try sealIfThresholdMet()
    }

    /// Removes live points by id. Unknown ids are ignored.
    ///
    /// Each successful removal increments the tombstone counter used by
    /// `count(includeTombstones: true)`. With a WAL, the delete is logged
    /// before memory is updated when the call returns successfully.
    public func delete(ids: [PointID]) throws {
        guard !ids.isEmpty else { return }
        try ensureAcceptingMutations()
        try throwIfStickyUnrecoverable()

        if let wal {
            // Still write a delete record even if some ids are unknown — replay
            // is idempotent and matches "caller asked to delete these ids".
            try appendRecords([.delete(ids: ids)], using: wal)
        }

        for id in ids {
            if live.removeValue(forKey: id) != nil {
                tombstoneCount += 1
            }
        }
        noteUnsealedMutation(pointCount: ids.count, vectorBytes: 0)
        try sealIfThresholdMet()
    }

    /// Fetches live points by id.
    ///
    /// Order matches `ids`. Missing ids are omitted. When `withVector` is false,
    /// returned points use an empty `vector` array (payload is still included).
    /// Reads ignore sticky fsync errors.
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
    /// `SearchRequest.ef` is ignored for flat search. Reads ignore sticky fsync errors.
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
    /// Reads ignore sticky fsync errors.
    public func count(includeTombstones: Bool = false) -> Int {
        if includeTombstones {
            return live.count + tombstoneCount
        }
        return live.count
    }

    /// Flushes durable state when a WAL is present.
    ///
    /// When there is unsealed data and a path-backed layout, materializes a sealed
    /// segment (VECTORS/IDS/PAYLOAD + SEGMENT_META), appends a seal WAL record,
    /// publishes MANIFEST, and reclaims the WAL. Otherwise appends a
    /// `checkpointMark` and **fsyncs** (S14 durability barrier for every level).
    public func checkpoint() throws {
        try ensureAcceptingMutations()
        guard wal != nil else { return }
        if hasUnsealedData, layout != nil, !live.isEmpty {
            try sealMutable()
            return
        }
        // Retry path: does not short-circuit on sticky; attempts barrier fsync.
        try appendSyncedOrThrow(.checkpointMark)
    }

    /// Forces a seal of the current live set when path-backed (test / advanced use).
    ///
    /// No-op when there is no layout/WAL, no live points, or nothing unsealed.
    public func seal() throws {
        try ensureAcceptingMutations()
        try sealMutable()
    }

    /// Stops mutations and optionally fsyncs the WAL.
    ///
    /// - Parameter syncWAL: When `true` (`Database.close`), try-fsync for all
    ///   durability levels. When `false` (`Database.dropCollection`), cancel
    ///   deferred work only — directory delete follows.
    ///
    /// Does not fsync in `deinit`; callers must use this lifecycle API.
    package func prepareForClose(syncWAL: Bool) throws {
        acceptingMutations = false
        flushTask?.cancel()
        flushTask = nil

        guard syncWAL else { return }

        guard wal != nil else {
            markDurableSuccess()
            return
        }
        try syncOrThrow()
    }

    // MARK: - Durability helpers (S14)

    private func appendRecords(_ records: [WALRecord], using wal: WriteAheadLog) throws {
        switch durability {
        case .strict:
            _ = try appendSyncedOrThrow(contentsOf: records)
        case .balanced:
            let bytes = try wal.append(contentsOf: records, sync: false)
            try registerPendingAndMaybeSync(recordCount: records.count, bytes: bytes)
        case .relaxed:
            _ = try wal.append(contentsOf: records, sync: false)
        }
    }

    private func markDurableSuccess() {
        stickySyncError = nil
        pendingRecordCount = 0
        pendingByteCount = 0
        hasPendingSync = false
        flushTask?.cancel()
        flushTask = nil
    }

    private func recordSyncFailure(_ error: Error) {
        if let vs = error as? VectorSwiftError {
            stickySyncError = vs
        } else {
            stickySyncError = .io(String(describing: error))
        }
    }

    private func syncOrThrow() throws {
        guard let wal else { return }
        do {
            try wal.synchronize()
            markDurableSuccess()
        } catch {
            recordSyncFailure(error)
            throw stickySyncError!
        }
    }

    @discardableResult
    private func appendSyncedOrThrow(_ record: WALRecord) throws -> Int {
        guard let wal else { return 0 }
        do {
            let bytes = try wal.append(record, sync: true)
            markDurableSuccess()
            return bytes
        } catch {
            recordSyncFailure(error)
            throw stickySyncError!
        }
    }

    @discardableResult
    private func appendSyncedOrThrow(contentsOf records: [WALRecord]) throws -> Int {
        guard let wal else { return 0 }
        do {
            let bytes = try wal.append(contentsOf: records, sync: true)
            markDurableSuccess()
            return bytes
        } catch {
            recordSyncFailure(error)
            throw stickySyncError!
        }
    }

    private func ensureAcceptingMutations() throws {
        if !acceptingMutations {
            throw VectorSwiftError.closed
        }
    }

    private func throwIfStickyUnrecoverable() throws {
        if let stickySyncError {
            throw stickySyncError
        }
    }

    private func registerPendingAndMaybeSync(recordCount: Int, bytes: Int) throws {
        pendingRecordCount += recordCount
        pendingByteCount += bytes
        hasPendingSync = true
        if pendingRecordCount >= balancedPolicy.syncEveryRecords
            || pendingByteCount >= balancedPolicy.syncEveryBytes
        {
            try syncOrThrow()
            return
        }
        scheduleCoalescedFlushIfNeeded()
    }

    private func scheduleCoalescedFlushIfNeeded() {
        guard durability == .balanced, flushTask == nil, hasPendingSync else { return }
        let ns = balancedPolicy.syncIntervalNanoseconds
        flushTask = Task {
            do {
                try await Task.sleep(nanoseconds: ns)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await self.performDeferredBalancedSync()
        }
    }

    private func performDeferredBalancedSync() async {
        flushTask = nil
        guard !Task.isCancelled else { return }
        guard durability == .balanced, hasPendingSync, wal != nil else { return }
        do {
            try syncOrThrow()
        } catch {
            // sticky already recorded; do not rethrow to original caller
        }
    }

    // MARK: - Seal (mutable → sealed segment)

    private func noteUnsealedMutation(pointCount: Int, vectorBytes: Int) {
        hasUnsealedData = true
        unsealedPointCount += pointCount
        unsealedByteCount += vectorBytes
    }

    private func sealIfThresholdMet() throws {
        guard layout != nil, wal != nil, hasUnsealedData else { return }
        if unsealedPointCount >= mutableSegmentMaxPoints
            || unsealedByteCount >= mutableSegmentMaxBytes
        {
            try sealMutable()
        }
    }

    /// Full-snapshot seal: write all live points to one segment, replace MANIFEST,
    /// append seal_segment_v2, reclaim WAL, drop prior segment dirs.
    private func sealMutable() throws {
        guard let layout, let wal else { return }
        guard hasUnsealedData, !live.isEmpty else { return }

        let segmentId = nextSegmentId
        let rows: [SealedSegmentIO.Row] = live.map { id, entry in
            SealedSegmentIO.Row(id: id, vector: entry.vector, payload: entry.payload)
        }

        let written = try SealedSegmentIO.writeSegment(
            segmentId: segmentId,
            dimension: collectionConfig.dimension,
            index: collectionConfig.index,
            rows: rows,
            segmentDirectory: layout.segmentDirectory(collection: name, segmentId: segmentId),
            vectorsURL: layout.vectorsBin(collection: name, segmentId: segmentId),
            idsURL: layout.idsBin(collection: name, segmentId: segmentId),
            payloadURL: layout.payloadBin(collection: name, segmentId: segmentId),
            metaURL: layout.segmentMeta(collection: name, segmentId: segmentId)
        )

        let sealPayload = WALSealSegmentV2Payload(
            segmentId: written.segmentId,
            rowCount: written.rowCount,
            vectorsCrc32: written.vectorsCrc32,
            idsCrc32: written.idsCrc32,
            payloadsCrc32: written.payloadsCrc32
        )
        _ = try appendSyncedOrThrow(.sealSegmentV2(sealPayload))

        var manifest = ManifestDocument.empty
        if JSONFileStore.exists(layout.manifest(collection: name)) {
            manifest = try JSONFileStore.read(
                ManifestDocument.self,
                from: layout.manifest(collection: name)
            )
        }
        let previousIds = manifest.segmentIds
        manifest.generation += 1
        manifest.segmentIds = [segmentId]
        manifest.walEpoch += 1
        try JSONFileStore.writeAtomic(manifest, to: layout.manifest(collection: name))
        try Self.fsyncFile(at: layout.manifest(collection: name))

        // Reclaim pre-seal frames; live remains the source of truth in memory.
        try wal.resetEmpty()
        markDurableSuccess()

        nextSegmentId = segmentId + 1
        try persistCollectionMeta(layout: layout)

        // Best-effort remove superseded segment directories.
        for oldId in previousIds where oldId != segmentId {
            let dir = layout.segmentDirectory(collection: name, segmentId: oldId)
            try? FileManager.default.removeItem(at: dir)
        }

        hasUnsealedData = false
        unsealedPointCount = 0
        unsealedByteCount = 0
    }

    private func persistCollectionMeta(layout: DatabaseLayout) throws {
        let meta = CollectionMetaDocument(
            config: collectionConfig,
            nextSegmentId: nextSegmentId,
            nextRowId: 1
        )
        try JSONFileStore.writeAtomic(meta, to: layout.collectionMeta(name: name))
    }

    private static func fsyncFile(at url: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to fsync \(url.path): \(error)")
        }
    }

    private static func loadSealedIntoLive(
        layout: DatabaseLayout,
        collectionName: String,
        dimension: Int,
        live: inout [PointID: Entry]
    ) throws {
        let manifestURL = layout.manifest(collection: collectionName)
        guard JSONFileStore.exists(manifestURL) else { return }

        let manifest = try JSONFileStore.read(ManifestDocument.self, from: manifestURL)
        if manifest.formatVersion != StorageFormat.version {
            throw VectorSwiftError.corrupted(
                path: manifestURL.path,
                reason: "Unsupported MANIFEST formatVersion \(manifest.formatVersion)"
            )
        }

        for segmentId in manifest.segmentIds {
            let rows = try SealedSegmentIO.loadSegment(
                segmentId: segmentId,
                expectedDimension: dimension,
                vectorsURL: layout.vectorsBin(collection: collectionName, segmentId: segmentId),
                idsURL: layout.idsBin(collection: collectionName, segmentId: segmentId),
                payloadURL: layout.payloadBin(collection: collectionName, segmentId: segmentId),
                metaURL: layout.segmentMeta(collection: collectionName, segmentId: segmentId)
            )
            for row in rows {
                live[row.id] = Entry(vector: row.vector, payload: row.payload)
            }
        }
    }

    // MARK: - Internals

    /// Applies a single WAL record to in-memory state (no further WAL writes).
    private static func applyRecord(
        _ record: WALRecord,
        into live: inout [PointID: Entry],
        tombstoneCount: inout Int,
        expectedDimension: Int,
        validateDimension: Bool
    ) throws {
        switch record {
        case .upsert(let id, let vector, let payload):
            if validateDimension {
                try VectorValidation.requireDimension(vector, expected: expectedDimension)
            }
            live[id] = Entry(vector: vector, payload: payload)
        case .delete(let ids):
            for id in ids {
                if live.removeValue(forKey: id) != nil {
                    tombstoneCount += 1
                }
            }
        case .checkpointMark:
            break
        case .sealSegment, .sealSegmentV2:
            // Segment rows are loaded from MANIFEST files before WAL replay.
            // Seal records are accepted so logs remain readable.
            break
        }
    }

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
