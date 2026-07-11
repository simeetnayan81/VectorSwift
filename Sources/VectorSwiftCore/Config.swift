/// Index family selected for a collection.
public enum IndexConfig: String, Sendable, Codable, Equatable, CaseIterable {
    case flat
    case hnsw
}

/// Parameters for hierarchical NSW graph construction and search.
public struct HNSWParams: Sendable, Codable, Equatable {
    public var m: Int
    public var efConstruction: Int
    public var efSearch: Int
    /// Max degree on layer 0. When `nil`, effective value is `2 * m`.
    public var maxM0: Int?
    /// Optional RNG seed for deterministic level assignment (tests).
    public var seed: UInt64?

    public init(
        m: Int = 16,
        efConstruction: Int = 200,
        efSearch: Int = 64,
        maxM0: Int? = nil,
        seed: UInt64? = nil
    ) {
        self.m = m
        self.efConstruction = efConstruction
        self.efSearch = efSearch
        self.maxM0 = maxM0
        self.seed = seed
    }

    public static let `default` = HNSWParams()

    /// Resolved layer-0 max degree.
    public var resolvedMaxM0: Int {
        maxM0 ?? (m * 2)
    }
}

/// How aggressively writes are forced to stable storage.
public enum DurabilityLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Memory-first; best-effort flush. May lose recent acks on crash.
    case relaxed
    /// WAL append on write; group fsync on interval, size, or checkpoint.
    case balanced
    /// fsync WAL before upsert/delete returns.
    case strict
}

/// Which distance backend to use.
public enum ComputeBackendPreference: String, Sendable, Codable, Equatable, CaseIterable {
    /// Prefer MLX when available and the batch is large enough; otherwise CPU.
    case auto
    case cpu
    /// Require MLX; fail if unavailable.
    case mlx
}

/// Per-collection configuration. Dimension and metric are fixed after create.
public struct CollectionConfig: Sendable, Codable, Equatable {
    public var name: String
    public var dimension: Int
    public var metric: DistanceMetric
    public var index: IndexConfig
    /// When true, vectors are L2-normalized on upsert.
    public var normalizeVectors: Bool
    public var hnsw: HNSWParams?

    public init(
        name: String,
        dimension: Int,
        metric: DistanceMetric,
        index: IndexConfig = .flat,
        normalizeVectors: Bool = false,
        hnsw: HNSWParams? = nil
    ) {
        self.name = name
        self.dimension = dimension
        self.metric = metric
        self.index = index
        self.normalizeVectors = normalizeVectors
        self.hnsw = hnsw
    }
}

/// Database-wide runtime configuration.
public struct DatabaseConfig: Sendable, Codable, Equatable {
    public var durability: DurabilityLevel
    public var compute: ComputeBackendPreference
    public var mutableSegmentMaxPoints: Int
    public var mutableSegmentMaxBytes: Int
    public var tombstoneRatioCompact: Double

    public init(
        durability: DurabilityLevel = .balanced,
        compute: ComputeBackendPreference = .auto,
        mutableSegmentMaxPoints: Int = 10_000,
        mutableSegmentMaxBytes: Int = 64 * 1024 * 1024,
        tombstoneRatioCompact: Double = 0.20
    ) {
        self.durability = durability
        self.compute = compute
        self.mutableSegmentMaxPoints = mutableSegmentMaxPoints
        self.mutableSegmentMaxBytes = mutableSegmentMaxBytes
        self.tombstoneRatioCompact = tombstoneRatioCompact
    }

    public static let `default` = DatabaseConfig()
}
