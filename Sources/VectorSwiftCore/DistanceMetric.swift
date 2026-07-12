/// Distance metric fixed on a collection at creation time.
///
/// All metrics are exposed to ranking as **smaller distance = closer**. See
/// `VectorDistance` for formulas and edge cases (especially cosine and zero norms).
public enum DistanceMetric: String, Sendable, Codable, CaseIterable, Equatable {
    /// Euclidean distance.
    case l2
    /// Squared Euclidean distance (same order as `l2`).
    case l2Squared
    /// Negative inner product for min-distance ranking.
    case innerProduct
    /// Angular distance as `1 - cosine_similarity`.
    case cosine
}
