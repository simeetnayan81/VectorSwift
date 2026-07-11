/// Shared size limits for identifiers and names.
public enum VectorSwiftLimits: Sendable {
    /// Maximum UTF-8 byte length of a public point id.
    public static let maxPointIDUTF8ByteCount = 512
    /// Maximum UTF-8 byte length of a collection name.
    public static let maxCollectionNameUTF8ByteCount = 128
}
