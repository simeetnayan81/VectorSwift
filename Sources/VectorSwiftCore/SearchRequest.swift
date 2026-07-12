/// Parameters for a nearest-neighbor query against a collection.
///
/// - `vector` / `k` drive exact flat search today.
/// - `filter` is part of the public request shape for metadata constraints; the
///   collection does not evaluate it yet.
/// - `ef` is reserved for approximate indexes that use a candidate list width;
///   exact flat search ignores it.
public struct SearchRequest: Sendable, Codable, Equatable {
    public var vector: [Float]
    public var k: Int
    public var filter: Filter?
    /// Candidate list size for approximate indexes; unused by exact (flat) search.
    public var ef: Int?
    public var withPayload: Bool
    public var withVector: Bool

    public init(
        vector: [Float],
        k: Int,
        filter: Filter? = nil,
        ef: Int? = nil,
        withPayload: Bool = true,
        withVector: Bool = false
    ) {
        self.vector = vector
        self.k = k
        self.filter = filter
        self.ef = ef
        self.withPayload = withPayload
        self.withVector = withVector
    }
}
