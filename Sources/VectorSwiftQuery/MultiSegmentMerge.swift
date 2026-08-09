import VectorSwiftCore

/// Merges per-segment exact top-k lists into a global top-k (design §9.1).
///
/// Each input list should already be sorted by nondecreasing distance. Duplicate
/// public ids (should not happen if callers apply last-write-wins / `isLive`)
/// are kept once: after global ordering, the first occurrence wins.
public enum MultiSegmentMerge {
    /// Returns up to `k` hits, smaller distance first; ties break by `PointID` ascending.
    public static func topK(_ parts: [[ScoredPoint]], k: Int) -> [ScoredPoint] {
        guard k >= 1 else { return [] }
        var combined: [ScoredPoint] = []
        combined.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts {
            combined.append(contentsOf: part)
        }
        combined.sort { a, b in
            if a.distance != b.distance {
                return a.distance < b.distance
            }
            return a.id < b.id
        }

        var seen = Set<PointID>()
        var result: [ScoredPoint] = []
        result.reserveCapacity(min(k, combined.count))
        for hit in combined {
            if seen.contains(hit.id) { continue }
            seen.insert(hit.id)
            result.append(hit)
            if result.count == k { break }
        }
        return result
    }
}
