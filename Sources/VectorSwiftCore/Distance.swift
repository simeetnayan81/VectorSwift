/// Pairwise vector distances. Every metric uses **smaller = closer**.
public enum VectorDistance {
    /// - Throws: `invalidArgument` if lengths differ.
    /// - Note: Cosine with a zero-norm vector returns `1` (cos treated as 0).
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
    /// Callers must ensure each pointer is valid for `dim` elements.
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

    /// 1 − cos(a, b); zero-norm → 1.
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
