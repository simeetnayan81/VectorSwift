import VectorSwiftCore

/// CPU `VectorCompute` backend that scores each row with `VectorDistance`.
///
/// This is the default, always-available implementation: correct, portable, and
/// independent of Metal/MLX. It walks the row-major matrix in Swift and reuses
/// the shared pointer-based distance formulas so behavior matches the reference
/// oracle used in tests.
///
/// Performance-oriented backends (vectorized CPU, GPU) should be separate types
/// conforming to `VectorCompute`, not forks of index logic. Compare them against
/// this type or `VectorDistance` when adding them.
public struct PortableCPUCompute: VectorCompute {
    public init() {}

    public func distances(
        query: [Float],
        database: UnsafeBufferPointer<Float>,
        count: Int,
        dim: Int,
        metric: DistanceMetric
    ) throws -> [Float] {
        guard count >= 0, dim >= 0 else {
            throw VectorSwiftError.invalidArgument(
                "count and dim must be non-negative (count=\(count), dim=\(dim))"
            )
        }
        guard query.count == dim else {
            throw VectorSwiftError.invalidDimension(expected: dim, actual: query.count)
        }
        guard count == 0 || dim == 0 || database.count >= count * dim else {
            throw VectorSwiftError.invalidArgument(
                "Database buffer too short: need \(count * dim) floats, have \(database.count)"
            )
        }
        if count == 0 {
            return []
        }
        // Empty dimensionality: each "row" is an empty vector; distance is well-defined.
        if dim == 0 {
            return try (0..<count).map { _ in
                try VectorDistance.distance(query, [], metric: metric)
            }
        }

        guard let dbBase = database.baseAddress else {
            throw VectorSwiftError.invalidArgument("Database buffer has no base address")
        }

        return try query.withUnsafeBufferPointer { queryBuf in
            guard let qBase = queryBuf.baseAddress else {
                throw VectorSwiftError.invalidArgument("Query buffer has no base address")
            }
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let row = dbBase.advanced(by: i * dim)
                out[i] = VectorDistance.distance(
                    aBase: qBase,
                    bBase: row,
                    dim: dim,
                    metric: metric
                )
            }
            return out
        }
    }
}
