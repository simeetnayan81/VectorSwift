/// Shared validation and vector transforms used by collections and the public API.
public enum VectorValidation {
    /// Ensures a point id is non-empty and within the UTF-8 byte limit.
    public static func requirePointID(_ id: PointID) throws {
        if id.isEmpty {
            throw VectorSwiftError.invalidPointID(id)
        }
        if id.utf8.count > VectorSwiftLimits.maxPointIDUTF8ByteCount {
            throw VectorSwiftError.invalidPointID(id)
        }
    }

    /// Ensures a collection name is non-empty and within the UTF-8 byte limit.
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

    /// Ensures `vector.count == expected`.
    public static func requireDimension(_ vector: [Float], expected: Int) throws {
        if vector.count != expected {
            throw VectorSwiftError.invalidDimension(expected: expected, actual: vector.count)
        }
    }

    /// Returns an L2-normalized copy of `vector`.
    ///
    /// - Throws: `VectorSwiftError.zeroVectorNotAllowed` if the Euclidean norm is zero
    ///   (normalization would be undefined).
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
