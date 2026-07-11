/// Errors thrown by VectorSwift APIs.
public enum VectorSwiftError: Error, Sendable, Equatable {
    case collectionExists(String)
    case collectionNotFound(String)
    case invalidDimension(expected: Int, actual: Int)
    case invalidPointID(String)
    case invalidArgument(String)
    case zeroVectorNotAllowed
    case backendUnavailable(String)
    case corrupted(path: String, reason: String)
    case io(String)
    case durability(String)
    case closed
    case internalInconsistency(String)
}

extension VectorSwiftError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .collectionExists(let name):
            return "Collection already exists: \(name)"
        case .collectionNotFound(let name):
            return "Collection not found: \(name)"
        case .invalidDimension(let expected, let actual):
            return "Invalid dimension: expected \(expected), got \(actual)"
        case .invalidPointID(let id):
            return "Invalid point id: \(id)"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .zeroVectorNotAllowed:
            return "Zero vector is not allowed when normalization is required"
        case .backendUnavailable(let name):
            return "Compute backend unavailable: \(name)"
        case .corrupted(let path, let reason):
            return "Corrupted data at \(path): \(reason)"
        case .io(let message):
            return "I/O error: \(message)"
        case .durability(let message):
            return "Durability error: \(message)"
        case .closed:
            return "Database is closed"
        case .internalInconsistency(let message):
            return "Internal inconsistency: \(message)"
        }
    }
}
