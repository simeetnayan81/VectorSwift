/// A stored vector row with optional metadata.
///
/// `id` is the public identifier used by clients. `vector` holds float32 components
/// (length must match the collection dimension on upsert). `payload` is a schemaless
/// map for application metadata (tags, language, etc.).
public struct Point: Sendable, Codable, Equatable {
    public var id: PointID
    public var vector: [Float]
    public var payload: [String: PayloadValue]

    public init(
        id: PointID,
        vector: [Float],
        payload: [String: PayloadValue] = [:]
    ) {
        self.id = id
        self.vector = vector
        self.payload = payload
    }
}

/// One neighbor returned from search.
///
/// `distance` always uses the collection metric with **smaller = closer**.
/// `payload` and `vector` are populated only when the corresponding flags on
/// `SearchRequest` are true.
public struct ScoredPoint: Sendable, Codable, Equatable {
    public var id: PointID
    public var distance: Float
    public var payload: [String: PayloadValue]?
    public var vector: [Float]?

    public init(
        id: PointID,
        distance: Float,
        payload: [String: PayloadValue]? = nil,
        vector: [Float]? = nil
    ) {
        self.id = id
        self.distance = distance
        self.payload = payload
        self.vector = vector
    }
}
