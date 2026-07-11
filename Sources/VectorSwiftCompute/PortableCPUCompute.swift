import VectorSwiftCore

/// Portable CPU implementation of `VectorCompute` (per-row `VectorDistance`).
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
