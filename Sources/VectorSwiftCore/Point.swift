/// Stored vector row with optional payload.
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

/// Ranked neighbor from search (`distance`: smaller = closer).
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
