/// Pairwise distance functions for dense float vectors.
///
/// ## Ranking convention
/// Every metric returns a value where **smaller means closer**. Indexes and heaps
/// can always minimize a single quantity. For inner product, a higher-is-better
/// similarity is available as `similarity = -distance`.
///
/// ## Metrics
/// - **l2**: Euclidean length of the difference, `||a - b||_2`.
/// - **l2Squared**: `||a - b||_2^2` (same ordering as L2, cheaper without sqrt).
/// - **innerProduct**: `-(a · b)` so a larger dot product ranks as closer.
/// - **cosine**: `1 - cos(a, b)`. Same direction → `0`; orthogonal unit vectors → `1`.
///   If either vector has zero L2 norm, cosine is treated as `0` and distance is `1`
///   so callers never hit division by zero.
///
/// ## Role in the stack
/// This type is the **reference implementation** of metric math. Batch backends
/// conforming to `VectorCompute` must match these results within normal float32
/// tolerance. Use the `[Float]` API for ad-hoc pairs; use the pointer API when
/// scanning a contiguous matrix so formulas stay shared and allocation-free per row.
public enum VectorDistance {
    /// Distance between two equal-length vectors.
    ///
    /// - Parameters:
    ///   - a: First vector.
    ///   - b: Second vector; must have the same length as `a`.
    ///   - metric: Distance metric.
    /// - Returns: Distance (smaller = closer).
    /// - Throws: `VectorSwiftError.invalidArgument` if `a.count != b.count`.
    public static func distance(
        _ a: [Float],
        _ b: [Float],
        metric: DistanceMetric
    ) throws -> Float {
        guard a.count == b.count else {
            throw VectorSwiftError.invalidArgument(
                "Vector length mismatch: \(a.count) vs \(b.count)"
            )
        }
        return a.withUnsafeBufferPointer { aBuf in
            b.withUnsafeBufferPointer { bBuf in
                distance(
                    aBase: aBuf.baseAddress!,
                    bBase: bBuf.baseAddress!,
                    dim: a.count,
                    metric: metric
                )
            }
        }
    }

    /// Distance between two contiguous rows of length `dim`.
    ///
    /// Both pointers must refer to at least `dim` readable floats. Intended for
    /// bulk scans over a row-major matrix (query vs many database rows) while
    /// reusing the same arithmetic as the array-based API.
    ///
    /// - Parameters:
    ///   - aBase: Start of the first vector.
    ///   - bBase: Start of the second vector.
    ///   - dim: Number of dimensions (components) per vector.
    ///   - metric: Distance metric.
    /// - Returns: Distance (smaller = closer).
    public static func distance(
        aBase: UnsafePointer<Float>,
        bBase: UnsafePointer<Float>,
        dim: Int,
        metric: DistanceMetric
    ) -> Float {
        switch metric {
        case .l2:
            return l2Squared(aBase: aBase, bBase: bBase, dim: dim).squareRoot()
        case .l2Squared:
            return l2Squared(aBase: aBase, bBase: bBase, dim: dim)
        case .innerProduct:
            return -dot(aBase: aBase, bBase: bBase, dim: dim)
        case .cosine:
            return cosineDistance(aBase: aBase, bBase: bBase, dim: dim)
        }
    }

    // MARK: - Internals

    @usableFromInline
    static func dot(
        aBase: UnsafePointer<Float>,
        bBase: UnsafePointer<Float>,
        dim: Int
    ) -> Float {
        var sum: Float = 0
        for i in 0..<dim {
            sum += aBase[i] * bBase[i]
        }
        return sum
    }

    @usableFromInline
    static func l2Squared(
        aBase: UnsafePointer<Float>,
        bBase: UnsafePointer<Float>,
        dim: Int
    ) -> Float {
        var sum: Float = 0
        for i in 0..<dim {
            let d = aBase[i] - bBase[i]
            sum += d * d
        }
        return sum
    }

    /// Cosine distance `1 - cos(a,b)`. Zero-norm on either side returns `1`.
    @usableFromInline
    static func cosineDistance(
        aBase: UnsafePointer<Float>,
        bBase: UnsafePointer<Float>,
        dim: Int
    ) -> Float {
        var dotSum: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<dim {
            let ai = aBase[i]
            let bi = bBase[i]
            dotSum += ai * bi
            normA += ai * ai
            normB += bi * bi
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        if denom == 0 {
            return 1
        }
        return 1 - (dotSum / denom)
    }
}
