/// Collection distance metric. Results use **smaller = closer** (IP is negated).
public enum DistanceMetric: String, Sendable, Codable, CaseIterable, Equatable {
    case l2
    case l2Squared
    case innerProduct
    case cosine
}
