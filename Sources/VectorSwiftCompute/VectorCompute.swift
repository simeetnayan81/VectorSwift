import VectorSwiftCore

/// Batch distance computation used by indexes when scoring many rows at once.
///
/// ## Contract
/// For a query of length `dim` and a row-major matrix of `count` rows:
///
/// ```
/// database layout: [row0_0 .. row0_{dim-1}][row1_0 ..] ... [row_{count-1}_*]
/// result[i]        = distance(query, row i)   // smaller = closer
/// ```
///
/// Implementations must agree with `VectorDistance` for the same inputs within
/// ordinary float32 error. That keeps correctness tests stable when swapping
/// portable CPU for SIMD or GPU backends.
///
/// ## When to use
/// - **Use this protocol** for full scans (flat index, IVF list scans, etc.).
/// - **Do not** assume a single scalar Swift loop is the only implementation;
///   accelerated backends plug in here without changing index code.
public protocol VectorCompute: Sendable {
    /// Computes one distance from `query` to each database row.
    ///
    /// - Parameters:
    ///   - query: Query vector; length must equal `dim`.
    ///   - database: Contiguous storage holding `count * dim` floats, row-major.
    ///   - count: Number of rows `n` (may be zero).
    ///   - dim: Dimensionality of each row and of `query`.
    ///   - metric: Distance metric (smaller result = closer).
    /// - Returns: Array of length `count`.
    /// - Throws: `VectorSwiftError` for dimension mismatch, short buffers, or
    ///   invalid arguments.
    func distances(
        query: [Float],
        database: UnsafeBufferPointer<Float>,
        count: Int,
        dim: Int,
        metric: DistanceMetric
    ) throws -> [Float]
}
