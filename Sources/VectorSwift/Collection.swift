import Foundation
import VectorSwiftCore
import VectorSwiftCompute
import VectorSwiftIndex
import VectorSwiftQuery
import VectorSwiftStorage

/// Named set of points with fixed dimensionality and distance metric.
///
/// ## Storage model
/// Path-backed collections keep immutable **sealed segments** plus a **mutable**
/// overlay. Upserts/deletes append WAL frames, then update the overlay. Seal
/// (threshold or `checkpoint`) writes only the overlay (+ epoch tombstones) as a
/// new segment, **appends** it to `MANIFEST.json`, and reclaims the WAL.
/// Reopen loads MANIFEST segments in order (later ids win), applies per-segment
/// tombstones, then replays WAL records **after** the last published seal.
/// Segment directories not listed in MANIFEST are ignored and removed.
///
/// Ephemeral collections (no path) keep everything in the mutable map.
///
/// ## Durability
/// `DurabilityLevel` selects when the process waits for WAL data to reach stable
/// storage via `FileHandle.synchronize()`. All path-backed levels write WAL
/// frames before applying memory. See ``DurabilityLevel`` for loss windows.
///
/// ## Concurrency
/// `Collection` is an actor. All mutations and searches are serialized on that
/// actor, so callers can safely share one collection across tasks.
///
/// ## Search path
/// Exact `FlatIndex` search per sealed segment (skipping superseded/tombstoned
/// rows via `idIndex`) plus the mutable overlay, then
/// ``MultiSegmentMerge/topK(_:k:)``.
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

    private var sealed: [SealedSegment] = []
    private var mutable: [PointID: Entry] = [:]
    /// Last-write-wins location of every live public id.
    private var idIndex: [PointID: Location] = [:]
    /// Deletes of ids that still have a row in some sealed segment (this epoch).
    private var epochTombstones: Set<PointID> = []
    /// Count of deletes that removed a live id (for `count(includeTombstones:)`).
    private var tombstoneCount: Int = 0
    /// Next segment id to allocate (persisted in `COLL_META.json`).
    private var nextSegmentId: UInt64
    /// True when live has changed since the last successful seal (or open).
    private var hasUnsealedData: Bool = false
    /// Approximate mutable size for seal thresholds (ops / vector bytes since seal).
    private var unsealedPointCount: Int = 0
    private var unsealedByteCount: Int = 0

    // MARK: Durability state

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

    private enum Location: Sendable, Equatable {
        case sealed(segmentId: UInt64, row: UInt32)
        case mutable
    }

    private struct SealedSegment: Sendable {
        var id: UInt64
        var ids: [PointID]
        var vectors: [Float]
        var payloads: [[String: PayloadValue]]
        var tombstones: [PointID]

        var rowCount: Int { ids.count }

        func vector(at row: Int, dim: Int) -> [Float] {
            let start = row * dim
            return Array(vectors[start..<(start + dim)])
        }
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

        if let layout {
            try Self.loadSealed(
                layout: layout,
                collectionName: config.name,
                dimension: config.dimension,
                sealed: &sealed,
                idIndex: &idIndex
            )
            let repaired = StorageRecovery.repairedNextSegmentId(
                persisted: self.nextSegmentId,
                publishedSegmentIds: sealed.map(\.id)
            )
            if repaired != self.nextSegmentId {
                self.nextSegmentId = repaired
                try Self.persistCollectionMeta(
                    layout: layout,
                    name: config.name,
                    config: config,
                    nextSegmentId: repaired
                )
            }
        }

        if let wal {
            let records = try wal.readAllValidRecords(truncateIncompleteTail: true)
            let start = StorageRecovery.replayStartIndex(
                records: records,
                publishedSegmentIds: Set(sealed.map(\.id))
            )
            let toReplay = records[start...]
            for record in toReplay {
                try Self.applyRecord(
                    record,
                    sealed: sealed,
                    mutable: &mutable,
                    idIndex: &idIndex,
                    epochTombstones: &epochTombstones,
                    tombstoneCount: &tombstoneCount,
                    expectedDimension: config.dimension,
                    validateDimension: true
                )
            }
            if toReplay.contains(where: {
                switch $0 {
                case .upsert, .delete: return true
                default: return false
                }
            }) {
                hasUnsealedData = true
                unsealedPointCount = mutable.count + epochTombstones.count
                unsealedByteCount = mutable.values.reduce(0) { $0 + $1.vector.count * 4 }
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
            mutable[item.id] = Entry(vector: item.vector, payload: item.payload)
            idIndex[item.id] = .mutable
            epochTombstones.remove(item.id)
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
            try appendRecords([.delete(ids: ids)], using: wal)
        }

        for id in ids {
            Self.applyDelete(
                id,
                sealed: sealed,
                mutable: &mutable,
                idIndex: &idIndex,
                epochTombstones: &epochTombstones,
                tombstoneCount: &tombstoneCount
            )
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
        let dim = collectionConfig.dimension
        for id in ids {
            guard let entry = lookupLive(id, dim: dim) else { continue }
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

        if idIndex.isEmpty {
            return []
        }

        var query = request.vector
        if collectionConfig.normalizeVectors {
            query = try VectorValidation.normalized(query)
        }

        let dim = collectionConfig.dimension
        var parts: [[ScoredPoint]] = []
        parts.reserveCapacity(sealed.count + 1)

        for segment in sealed {
            let hits = try searchSealed(
                segment,
                query: query,
                k: request.k,
                dim: dim,
                withPayload: request.withPayload,
                withVector: request.withVector
            )
            if !hits.isEmpty {
                parts.append(hits)
            }
        }

        if !mutable.isEmpty {
            let hits = try searchMutable(
                query: query,
                k: request.k,
                dim: dim,
                withPayload: request.withPayload,
                withVector: request.withVector
            )
            if !hits.isEmpty {
                parts.append(hits)
            }
        }

        return MultiSegmentMerge.topK(parts, k: request.k)
    }

    /// Number of live points, or live + tombstone count when requested.
    /// Reads ignore sticky fsync errors.
    public func count(includeTombstones: Bool = false) -> Int {
        if includeTombstones {
            return idIndex.count + tombstoneCount
        }
        return idIndex.count
    }

    /// Flushes durable state when a WAL is present.
    ///
    /// When there is unsealed data and a path-backed layout, materializes a sealed
    /// segment (VECTORS/IDS/PAYLOAD/TOMBSTONES + SEGMENT_META), appends a seal WAL
    /// record, publishes MANIFEST (append segment id), and reclaims the WAL.
    /// Otherwise appends a `checkpointMark` and **fsyncs** (S14 durability barrier
    /// for every level).
    public func checkpoint() throws {
        try ensureAcceptingMutations()
        guard wal != nil else { return }
        if hasUnsealedData, layout != nil, hasSealableWork {
            try sealMutable()
            return
        }
        try appendSyncedOrThrow(.checkpointMark)
    }

    /// Forces a seal of the current mutable overlay when path-backed.
    ///
    /// No-op when there is no layout/WAL or nothing unsealed to materialize.
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

    private var hasSealableWork: Bool {
        !mutable.isEmpty || !epochTombstones.isEmpty
    }

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

    /// Incremental seal: write mutable rows + epoch tombstones, append MANIFEST.
    private func sealMutable() throws {
        guard let layout, let wal else { return }
        guard hasUnsealedData, hasSealableWork else { return }

        let segmentId = nextSegmentId
        nextSegmentId = segmentId + 1
        do {
            try Self.persistCollectionMeta(
                layout: layout,
                name: name,
                config: collectionConfig,
                nextSegmentId: nextSegmentId
            )
        } catch {
            nextSegmentId = segmentId
            throw error
        }

        let rows: [SealedSegmentIO.Row] = mutable.map { id, entry in
            SealedSegmentIO.Row(id: id, vector: entry.vector, payload: entry.payload)
        }
        let tombstones = epochTombstones.sorted()

        let written = try SealedSegmentIO.writeSegment(
            segmentId: segmentId,
            dimension: collectionConfig.dimension,
            index: collectionConfig.index,
            rows: rows,
            tombstones: tombstones,
            segmentDirectory: layout.segmentDirectory(collection: name, segmentId: segmentId),
            vectorsURL: layout.vectorsBin(collection: name, segmentId: segmentId),
            idsURL: layout.idsBin(collection: name, segmentId: segmentId),
            payloadURL: layout.payloadBin(collection: name, segmentId: segmentId),
            tombstonesURL: layout.tombstonesBin(collection: name, segmentId: segmentId),
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
        manifest.generation += 1
        if !manifest.segmentIds.contains(segmentId) {
            manifest.segmentIds.append(segmentId)
        }
        manifest.walEpoch += 1
        try JSONFileStore.writeAtomic(manifest, to: layout.manifest(collection: name))
        try Self.fsyncFile(at: layout.manifest(collection: name))

        try wal.resetEmpty()
        markDurableSuccess()

        var vectors: [Float] = []
        var ids: [PointID] = []
        var payloads: [[String: PayloadValue]] = []
        vectors.reserveCapacity(rows.count * collectionConfig.dimension)
        ids.reserveCapacity(rows.count)
        payloads.reserveCapacity(rows.count)
        for row in rows {
            ids.append(row.id)
            vectors.append(contentsOf: row.vector)
            payloads.append(row.payload)
        }
        let newSegment = SealedSegment(
            id: segmentId,
            ids: ids,
            vectors: vectors,
            payloads: payloads,
            tombstones: tombstones
        )
        sealed.append(newSegment)
        for (row, id) in ids.enumerated() {
            idIndex[id] = .sealed(segmentId: segmentId, row: UInt32(row))
        }
        for id in tombstones {
            idIndex.removeValue(forKey: id)
        }

        mutable.removeAll()
        epochTombstones.removeAll()
        hasUnsealedData = false
        unsealedPointCount = 0
        unsealedByteCount = 0
    }

    private static func persistCollectionMeta(
        layout: DatabaseLayout,
        name: String,
        config: CollectionConfig,
        nextSegmentId: UInt64
    ) throws {
        let meta = CollectionMetaDocument(
            config: config,
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

    private static func loadSealed(
        layout: DatabaseLayout,
        collectionName: String,
        dimension: Int,
        sealed: inout [SealedSegment],
        idIndex: inout [PointID: Location]
    ) throws {
        let manifestURL = layout.manifest(collection: collectionName)
        let manifest: ManifestDocument
        if JSONFileStore.exists(manifestURL) {
            let loaded = try JSONFileStore.read(ManifestDocument.self, from: manifestURL)
            if loaded.formatVersion != StorageFormat.version {
                throw VectorSwiftError.corrupted(
                    path: manifestURL.path,
                    reason: "Unsupported MANIFEST formatVersion \(loaded.formatVersion)"
                )
            }
            manifest = loaded
        } else {
            manifest = .empty
        }

        let collectionDir = layout.collectionDirectory(name: collectionName)
        _ = StorageRecovery.removeUnlistedSegmentDirectories(
            segmentsDirectory: layout.segmentsDirectory(collection: collectionName),
            liveSegmentIds: Set(manifest.segmentIds)
        )
        _ = StorageRecovery.removeLeftoverTemporaryFiles(in: collectionDir)
        for segmentId in manifest.segmentIds {
            _ = StorageRecovery.removeLeftoverTemporaryFiles(
                in: layout.segmentDirectory(collection: collectionName, segmentId: segmentId)
            )
        }

        for segmentId in manifest.segmentIds {
            let loaded = try SealedSegmentIO.loadSegment(
                segmentId: segmentId,
                expectedDimension: dimension,
                vectorsURL: layout.vectorsBin(collection: collectionName, segmentId: segmentId),
                idsURL: layout.idsBin(collection: collectionName, segmentId: segmentId),
                payloadURL: layout.payloadBin(collection: collectionName, segmentId: segmentId),
                tombstonesURL: layout.tombstonesBin(collection: collectionName, segmentId: segmentId),
                metaURL: layout.segmentMeta(collection: collectionName, segmentId: segmentId)
            )

            var vectors: [Float] = []
            var ids: [PointID] = []
            var payloads: [[String: PayloadValue]] = []
            vectors.reserveCapacity(loaded.rows.count * dimension)
            ids.reserveCapacity(loaded.rows.count)
            payloads.reserveCapacity(loaded.rows.count)
            for row in loaded.rows {
                ids.append(row.id)
                vectors.append(contentsOf: row.vector)
                payloads.append(row.payload)
            }

            sealed.append(
                SealedSegment(
                    id: segmentId,
                    ids: ids,
                    vectors: vectors,
                    payloads: payloads,
                    tombstones: loaded.tombstones
                )
            )

            for (row, id) in ids.enumerated() {
                idIndex[id] = .sealed(segmentId: segmentId, row: UInt32(row))
            }
            for id in loaded.tombstones {
                idIndex.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Internals

    private func lookupLive(_ id: PointID, dim: Int) -> Entry? {
        guard let loc = idIndex[id] else { return nil }
        switch loc {
        case .mutable:
            return mutable[id]
        case .sealed(let segmentId, let row):
            guard let segment = sealed.first(where: { $0.id == segmentId }) else {
                return nil
            }
            let r = Int(row)
            guard r < segment.rowCount else { return nil }
            return Entry(vector: segment.vector(at: r, dim: dim), payload: segment.payloads[r])
        }
    }

    private func searchSealed(
        _ segment: SealedSegment,
        query: [Float],
        k: Int,
        dim: Int,
        withPayload: Bool,
        withVector: Bool
    ) throws -> [ScoredPoint] {
        if segment.rowCount == 0 {
            return []
        }
        let liveIndex = idIndex
        let segmentId = segment.id
        let segmentIds = segment.ids
        let hits = try segment.vectors.withUnsafeBufferPointer { buffer in
            try FlatIndex.search(
                query: query,
                database: buffer,
                count: segment.rowCount,
                dim: dim,
                k: k,
                metric: collectionConfig.metric,
                compute: compute,
                isLive: { row in
                    let id = segmentIds[Int(row)]
                    if case .sealed(let sid, let r) = liveIndex[id], sid == segmentId, r == row {
                        return true
                    }
                    return false
                }
            )
        }
        return hits.map { hit in
            let i = Int(hit.row)
            return ScoredPoint(
                id: segment.ids[i],
                distance: hit.distance,
                payload: withPayload ? segment.payloads[i] : nil,
                vector: withVector ? segment.vector(at: i, dim: dim) : nil
            )
        }
    }

    private func searchMutable(
        query: [Float],
        k: Int,
        dim: Int,
        withPayload: Bool,
        withVector: Bool
    ) throws -> [ScoredPoint] {
        var ids: [PointID] = []
        var vectors: [[Float]] = []
        var payloads: [[String: PayloadValue]] = []
        ids.reserveCapacity(mutable.count)
        vectors.reserveCapacity(mutable.count)
        payloads.reserveCapacity(mutable.count)
        for (id, entry) in mutable {
            // Skip stale mutable entries that are not the live location.
            guard idIndex[id] == .mutable else { continue }
            ids.append(id)
            vectors.append(entry.vector)
            payloads.append(entry.payload)
        }
        guard !ids.isEmpty else { return [] }

        var matrix = [Float]()
        matrix.reserveCapacity(ids.count * dim)
        for vector in vectors {
            matrix.append(contentsOf: vector)
        }

        let hits = try matrix.withUnsafeBufferPointer { buffer in
            try FlatIndex.search(
                query: query,
                database: buffer,
                count: ids.count,
                dim: dim,
                k: k,
                metric: collectionConfig.metric,
                compute: compute
            )
        }
        return hits.map { hit in
            let i = Int(hit.row)
            return ScoredPoint(
                id: ids[i],
                distance: hit.distance,
                payload: withPayload ? payloads[i] : nil,
                vector: withVector ? vectors[i] : nil
            )
        }
    }

    private static func applyRecord(
        _ record: WALRecord,
        sealed: [SealedSegment],
        mutable: inout [PointID: Entry],
        idIndex: inout [PointID: Location],
        epochTombstones: inout Set<PointID>,
        tombstoneCount: inout Int,
        expectedDimension: Int,
        validateDimension: Bool
    ) throws {
        switch record {
        case .upsert(let id, let vector, let payload):
            if validateDimension {
                try VectorValidation.requireDimension(vector, expected: expectedDimension)
            }
            mutable[id] = Entry(vector: vector, payload: payload)
            idIndex[id] = .mutable
            epochTombstones.remove(id)
        case .delete(let ids):
            for id in ids {
                applyDelete(
                    id,
                    sealed: sealed,
                    mutable: &mutable,
                    idIndex: &idIndex,
                    epochTombstones: &epochTombstones,
                    tombstoneCount: &tombstoneCount
                )
            }
        case .checkpointMark:
            break
        case .sealSegment, .sealSegmentV2:
            break
        }
    }

    private static func applyDelete(
        _ id: PointID,
        sealed: [SealedSegment],
        mutable: inout [PointID: Entry],
        idIndex: inout [PointID: Location],
        epochTombstones: inout Set<PointID>,
        tombstoneCount: inout Int
    ) {
        if let loc = idIndex.removeValue(forKey: id) {
            tombstoneCount += 1
            if case .mutable = loc {
                mutable.removeValue(forKey: id)
            }
        } else {
            mutable.removeValue(forKey: id)
        }
        if sealed.contains(where: { $0.ids.contains(id) }) {
            epochTombstones.insert(id)
        }
    }
}
