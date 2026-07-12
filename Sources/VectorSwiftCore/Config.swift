/// Index structure used to accelerate search inside a collection.
///
/// Only `.flat` (exact scan) is implemented. Other cases may appear in configuration
/// for forward compatibility but collection creation will reject unsupported values.
public enum IndexConfig: String, Sendable, Codable, Equatable, CaseIterable {
    case flat
    case hnsw
}

/// Parameters for hierarchical NSW graph indexes.
///
/// Used when an approximate graph index is available. Defaults match common practice
/// (M=16, efConstruction=200, efSearch=64; layer-0 max degree defaults to `2 * m`).
public struct HNSWParams: Sendable, Codable, Equatable {
    public var m: Int
    public var efConstruction: Int
    public var efSearch: Int
    /// Max degree on layer 0. When `nil`, effective value is `2 * m`.
    public var maxM0: Int?
    /// Optional RNG seed so level assignment can be repeated in tests.
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

    /// Resolved layer-0 maximum degree.
    public var resolvedMaxM0: Int {
        maxM0 ?? (m * 2)
    }
}

/// How aggressively writes are forced to stable storage once durability exists.
public enum DurabilityLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Memory-first; best-effort flush. May lose recent acks on crash.
    case relaxed
    /// WAL append on write; group fsync on interval, size, or checkpoint.
    case balanced
    /// fsync WAL before upsert/delete returns.
    case strict
}

/// Preferred distance backend for a database instance.
public enum ComputeBackendPreference: String, Sendable, Codable, Equatable, CaseIterable {
    /// Prefer an accelerated backend when available and beneficial; otherwise CPU.
    case auto
    /// Always use the portable CPU implementation.
    case cpu
    /// Require an MLX (or equivalent) backend; fail if unavailable.
    case mlx
}

/// Per-collection configuration. Dimension and metric are fixed after create.
public struct CollectionConfig: Sendable, Codable, Equatable {
    public var name: String
    public var dimension: Int
    public var metric: DistanceMetric
    public var index: IndexConfig
    /// When true, vectors are L2-normalized on upsert (and queries on search).
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
///
/// Segment size and durability fields are stored for API stability and will apply
/// when on-disk segments and WAL are enabled. `compute` selects the distance backend
/// shared by collections created through the database.
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
