/// Parameters for a nearest-neighbor query.
public struct SearchRequest: Sendable, Codable, Equatable {
    public var vector: [Float]
    public var k: Int
    public var filter: Filter?
    /// HNSW search-width override; ignored by flat index.
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
