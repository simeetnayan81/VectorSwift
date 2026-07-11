import VectorSwiftCore

/// Batch distance kernels used by indexes (one query vs many rows).
///
/// Results must match `VectorDistance` within floating-point tolerance.
public protocol VectorCompute: Sendable {
    /// `distances[i]` is the distance from `query` to row `i`.
    ///
    /// - Parameters:
    ///   - query: Length must equal `dim`.
    ///   - database: Row-major buffer of `count * dim` floats.
    ///   - count: Number of rows.
    ///   - dim: Dimensions per row.
    ///   - metric: Smaller distance means closer.
    func distances(
        query: [Float],
        database: UnsafeBufferPointer<Float>,
        count: Int,
        dim: Int,
        metric: DistanceMetric
    ) throws -> [Float]
}
