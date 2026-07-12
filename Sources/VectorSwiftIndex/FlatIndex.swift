import VectorSwiftCore
import VectorSwiftCompute

/// One neighbor from a flat (exact) search, identified by matrix row.
public struct FlatIndexHit: Sendable, Equatable {
    public var row: UInt32
    /// Smaller means closer.
    public var distance: Float

    public init(row: UInt32, distance: Float) {
        self.row = row
        self.distance = distance
    }
}

/// Exact k-NN over a contiguous row-major vector matrix.
public enum FlatIndex {
    /// Returns up to `k` nearest live rows, sorted by nondecreasing distance.
    /// Ties break by ascending `row`.
    ///
    /// - Parameters:
    ///   - isLive: Optional filter; when `nil`, every row is eligible.
    public static func search(
        query: [Float],
        database: UnsafeBufferPointer<Float>,
        count: Int,
        dim: Int,
        k: Int,
        metric: DistanceMetric,
        compute: any VectorCompute,
        isLive: ((UInt32) -> Bool)? = nil
    ) throws -> [FlatIndexHit] {
        guard k >= 1 else {
            throw VectorSwiftError.invalidArgument("k must be >= 1, got \(k)")
        }
        guard count >= 0, dim >= 0 else {
            throw VectorSwiftError.invalidArgument(
                "count and dim must be non-negative (count=\(count), dim=\(dim))"
            )
        }
        if count == 0 {
            return []
        }

        let distances = try compute.distances(
            query: query,
            database: database,
            count: count,
            dim: dim,
            metric: metric
        )

        // Max-heap of size at most k: root is the worst (largest distance) of the keepers.
        var heap: [FlatIndexHit] = []
        heap.reserveCapacity(min(k, count))

        for i in 0..<count {
            let row = UInt32(i)
            if let isLive, !isLive(row) {
                continue
            }
            let hit = FlatIndexHit(row: row, distance: distances[i])
            if heap.count < k {
                heapAppend(&heap, hit)
            } else if isBetter(hit, than: heap[0]) {
                heapReplaceRoot(&heap, with: hit)
            }
        }

        // Ascending distance, then ascending row.
        heap.sort(by: isOrderedBefore)
        return heap
    }

    // MARK: - Ordering

    /// Strict preference for search results: smaller distance, then smaller row.
    @usableFromInline
    static func isOrderedBefore(_ a: FlatIndexHit, _ b: FlatIndexHit) -> Bool {
        if a.distance != b.distance {
            return a.distance < b.distance
        }
        return a.row < b.row
    }

    /// Whether `candidate` should replace `worst` in a top-k set.
    @usableFromInline
    static func isBetter(_ candidate: FlatIndexHit, than worst: FlatIndexHit) -> Bool {
        isOrderedBefore(candidate, worst)
    }

    // MARK: - Binary max-heap (worst-of-k at root)

    /// Heap order: parent is "worse" than children (larger distance, or same distance and larger row).
    private static func isWorse(_ a: FlatIndexHit, than b: FlatIndexHit) -> Bool {
        isOrderedBefore(b, a)
    }

    private static func heapAppend(_ heap: inout [FlatIndexHit], _ value: FlatIndexHit) {
        heap.append(value)
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if isWorse(heap[i], than: heap[parent]) {
                heap.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private static func heapReplaceRoot(_ heap: inout [FlatIndexHit], with value: FlatIndexHit) {
        heap[0] = value
        var i = 0
        while true {
            let left = 2 * i + 1
            let right = left + 1
            var worst = i
            if left < heap.count, isWorse(heap[left], than: heap[worst]) {
                worst = left
            }
            if right < heap.count, isWorse(heap[right], than: heap[worst]) {
                worst = right
            }
            if worst == i {
                break
            }
            heap.swapAt(i, worst)
            i = worst
        }
    }
}
