/// Shared validation for ids and vectors.
public enum VectorValidation {
    /// Validates a public point id.
    public static func requirePointID(_ id: PointID) throws {
        if id.isEmpty {
            throw VectorSwiftError.invalidPointID(id)
        }
        if id.utf8.count > VectorSwiftLimits.maxPointIDUTF8ByteCount {
            throw VectorSwiftError.invalidPointID(id)
        }
    }

    /// Validates collection name length and non-emptiness.
    public static func requireCollectionName(_ name: String) throws {
        if name.isEmpty {
            throw VectorSwiftError.invalidArgument("Collection name must not be empty")
        }
        if name.utf8.count > VectorSwiftLimits.maxCollectionNameUTF8ByteCount {
            throw VectorSwiftError.invalidArgument(
                "Collection name exceeds \(VectorSwiftLimits.maxCollectionNameUTF8ByteCount) UTF-8 bytes"
            )
        }
    }

    /// Validates vector length against collection dimension.
    public static func requireDimension(_ vector: [Float], expected: Int) throws {
        if vector.count != expected {
            throw VectorSwiftError.invalidDimension(expected: expected, actual: vector.count)
        }
    }

    /// L2-normalizes `vector`. Throws `zeroVectorNotAllowed` if the norm is zero.
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        var sumSquares: Float = 0
        for x in vector {
            sumSquares += x * x
        }
        let norm = sumSquares.squareRoot()
        if norm == 0 {
            throw VectorSwiftError.zeroVectorNotAllowed
        }
        return vector.map { $0 / norm }
    }
}
