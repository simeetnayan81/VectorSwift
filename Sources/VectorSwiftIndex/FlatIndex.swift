import VectorSwiftCore
import VectorSwiftCompute

/// One neighbor from an exact matrix search, identified by row index.
///
/// `row` is an index into the database matrix passed to ``FlatIndex/search``.
/// Mapping rows to public point IDs is the caller's responsibility (e.g. a
/// parallel `ids` array built when packing live points).
public struct FlatIndexHit: Sendable, Equatable {
    public var row: UInt32
    /// Distance under the requested metric; **smaller means closer**.
    public var distance: Float

    public init(row: UInt32, distance: Float) {
        self.row = row
        self.distance = distance
    }
}

/// Exact *k*-nearest-neighbor search over a dense row-major float matrix.
///
/// ## Algorithm
/// 1. Ask `compute` for the distance from the query to every row.
/// 2. Keep the best *k* live rows in a max-heap of size at most *k* (heap root is
///    the **worst** of the current top-k, so candidates can be compared in O(log k)).
/// 3. Sort the survivors by nondecreasing distance; ties break by ascending `row`
///    so results are deterministic when distances match.
///
/// ## Complexity
/// O(n · cost(distance) + n log k) for *n* rows. Correctness is identical to
/// sorting all distances and taking a prefix, which tests verify via a full-sort baseline.
///
/// ## Live filter
/// When `isLive` is non-nil, rows that return `false` are skipped. Use this to
/// ignore tombstoned or superseded rows without rebuilding the matrix.
public enum FlatIndex {
    /// Returns up to `k` nearest live rows, sorted best-first.
    ///
    /// - Parameters:
    ///   - query: Query vector of length `dim`.
    ///   - database: Row-major buffer of `count * dim` floats.
    ///   - count: Number of rows.
    ///   - dim: Dimensions per row.
    ///   - k: Maximum neighbors to return (`k >= 1`). If fewer than `k` live rows
    ///     exist, all live rows are returned.
    ///   - metric: Distance metric (must match how the collection was configured).
    ///   - compute: Batch distance backend.
    ///   - isLive: Optional predicate; `nil` means every row is eligible.
    /// - Throws: `VectorSwiftError` for invalid `k`, buffer/dimension problems, or
    ///   errors from `compute`.
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

        // Max-heap of size ≤ k: root holds the worst (largest distance) keeper.
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

        // Emit best-first: ascending distance, then ascending row for ties.
        heap.sort(by: isOrderedBefore)
        return heap
    }

    // MARK: - Ordering

    /// Preferred order for results: smaller distance first; if equal, smaller row.
    @usableFromInline
    static func isOrderedBefore(_ a: FlatIndexHit, _ b: FlatIndexHit) -> Bool {
        if a.distance != b.distance {
            return a.distance < b.distance
        }
        return a.row < b.row
    }

    /// Whether `candidate` should replace `worst` among the current top-k.
    @usableFromInline
    static func isBetter(_ candidate: FlatIndexHit, than worst: FlatIndexHit) -> Bool {
        isOrderedBefore(candidate, worst)
    }

    // MARK: - Binary max-heap (worst-of-k at root)

    /// Heap order: parent is “worse” than children (larger distance, or same distance and larger row).
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
