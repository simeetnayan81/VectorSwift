import XCTest
import VectorSwift
import VectorSwiftCompute

final class PortableCPUComputeTests: XCTestCase {
    private let accuracy: Float = 1e-5
    private let compute = PortableCPUCompute()

    /// Pack rows into a single row-major buffer.
    private func pack(_ rows: [[Float]]) -> (buffer: [Float], count: Int, dim: Int) {
        precondition(!rows.isEmpty)
        let dim = rows[0].count
        precondition(rows.allSatisfy { $0.count == dim })
        return (rows.flatMap { $0 }, rows.count, dim)
    }

    private func assertMatchesOracle(
        query: [Float],
        rows: [[Float]],
        metric: DistanceMetric,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let packed = pack(rows)
        let batch: [Float] = try packed.buffer.withUnsafeBufferPointer { db in
            try compute.distances(
                query: query,
                database: db,
                count: packed.count,
                dim: packed.dim,
                metric: metric
            )
        }
        XCTAssertEqual(batch.count, rows.count, file: file, line: line)
        for i in rows.indices {
            let expected = try VectorDistance.distance(query, rows[i], metric: metric)
            XCTAssertEqual(batch[i], expected, accuracy: accuracy, file: file, line: line)
        }
    }

    func testBatchMatchesOracle_allMetrics() throws {
        let query: [Float] = [1, 0, 0]
        let rows: [[Float]] = [
            [1, 0, 0],
            [0, 1, 0],
            [3, 4, 0],
            [0, 0, 0],
        ]
        for metric in DistanceMetric.allCases {
            try assertMatchesOracle(query: query, rows: rows, metric: metric)
        }
    }

    func testEmptyDatabaseReturnsEmpty() throws {
        let query: [Float] = [1, 2]
        let empty = [Float]()
        let result = try empty.withUnsafeBufferPointer { db in
            try compute.distances(
                query: query,
                database: db,
                count: 0,
                dim: 2,
                metric: .l2
            )
        }
        XCTAssertEqual(result, [])
    }

    func testWrongQueryDimensionThrows() {
        let db = [Float](repeating: 0, count: 6) // 2 rows × 3 dim
        XCTAssertThrowsError(
            try db.withUnsafeBufferPointer { buf in
                try compute.distances(
                    query: [1, 2],
                    database: buf,
                    count: 2,
                    dim: 3,
                    metric: .l2
                )
            }
        ) { error in
            guard case VectorSwiftError.invalidDimension(expected: 3, actual: 2) = error else {
                return XCTFail("Expected invalidDimension, got \(error)")
            }
        }
    }

    func testBufferTooShortThrows() {
        let db: [Float] = [1, 2, 3] // need 2*3=6
        XCTAssertThrowsError(
            try db.withUnsafeBufferPointer { buf in
                try compute.distances(
                    query: [0, 0, 0],
                    database: buf,
                    count: 2,
                    dim: 3,
                    metric: .l2
                )
            }
        ) { error in
            guard case VectorSwiftError.invalidArgument = error else {
                return XCTFail("Expected invalidArgument, got \(error)")
            }
        }
    }

    func testRandomBatchMatchesOracle() throws {
        var rng = SplitMix64(seed: 42)
        let dim = 16
        let count = 100
        let query = (0..<dim).map { _ in rng.nextFloat() }
        let rows: [[Float]] = (0..<count).map { _ in
            (0..<dim).map { _ in rng.nextFloat() }
        }
        for metric in DistanceMetric.allCases {
            try assertMatchesOracle(query: query, rows: rows, metric: metric)
        }
    }
}

/// Small deterministic RNG for tests (no Foundation dependency quirks).
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextFloat() -> Float {
        // Map to [-1, 1]
        let x = next() >> 40 // top 24 bits
        return Float(x) / Float(1 << 24) * 2 - 1
    }
}
