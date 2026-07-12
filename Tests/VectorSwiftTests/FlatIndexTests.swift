import XCTest
import VectorSwift
import VectorSwiftCompute
import VectorSwiftIndex

final class FlatIndexTests: XCTestCase {
    private let compute = PortableCPUCompute()
    private let accuracy: Float = 1e-5

    private func pack(_ rows: [[Float]]) -> (buffer: [Float], count: Int, dim: Int) {
        let dim = rows.first?.count ?? 0
        precondition(rows.allSatisfy { $0.count == dim })
        return (rows.flatMap { $0 }, rows.count, dim)
    }

    private func search(
        query: [Float],
        rows: [[Float]],
        k: Int,
        metric: DistanceMetric,
        isLive: ((UInt32) -> Bool)? = nil
    ) throws -> [FlatIndexHit] {
        let packed = pack(rows)
        return try packed.buffer.withUnsafeBufferPointer { db in
            try FlatIndex.search(
                query: query,
                database: db,
                count: packed.count,
                dim: packed.dim,
                k: k,
                metric: metric,
                compute: compute,
                isLive: isLive
            )
        }
    }

    /// Full sort baseline (same ordering rules).
    private func baseline(
        query: [Float],
        rows: [[Float]],
        k: Int,
        metric: DistanceMetric,
        isLive: ((UInt32) -> Bool)? = nil
    ) throws -> [FlatIndexHit] {
        var hits: [FlatIndexHit] = []
        for (i, row) in rows.enumerated() {
            let id = UInt32(i)
            if let isLive, !isLive(id) { continue }
            let d = try VectorDistance.distance(query, row, metric: metric)
            hits.append(FlatIndexHit(row: id, distance: d))
        }
        hits.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.row < $1.row
        }
        return Array(hits.prefix(k))
    }

    private func assertMatchesBaseline(
        query: [Float],
        rows: [[Float]],
        k: Int,
        metric: DistanceMetric,
        isLive: ((UInt32) -> Bool)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let got = try search(query: query, rows: rows, k: k, metric: metric, isLive: isLive)
        let expected = try baseline(query: query, rows: rows, k: k, metric: metric, isLive: isLive)
        XCTAssertEqual(got.count, expected.count, file: file, line: line)
        for i in got.indices {
            XCTAssertEqual(got[i].row, expected[i].row, file: file, line: line)
            XCTAssertEqual(got[i].distance, expected[i].distance, accuracy: accuracy, file: file, line: line)
        }
    }

    func testEmptyMatrix() throws {
        let hits = try [Float]().withUnsafeBufferPointer { db in
            try FlatIndex.search(
                query: [1, 2],
                database: db,
                count: 0,
                dim: 2,
                k: 3,
                metric: .l2,
                compute: compute
            )
        }
        XCTAssertEqual(hits, [])
    }

    func testKEqualsOne() throws {
        let rows: [[Float]] = [
            [0, 0],
            [3, 4],
            [1, 0],
        ]
        let query: [Float] = [0, 0]
        try assertMatchesBaseline(query: query, rows: rows, k: 1, metric: .l2)
        let hits = try search(query: query, rows: rows, k: 1, metric: .l2)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].row, 0)
        XCTAssertEqual(hits[0].distance, 0, accuracy: accuracy)
    }

    func testKEqualsN() throws {
        let rows: [[Float]] = [
            [1, 0],
            [0, 1],
            [1, 1],
        ]
        try assertMatchesBaseline(query: [1, 0], rows: rows, k: 3, metric: .l2)
    }

    func testKLargerThanNReturnsAll() throws {
        let rows: [[Float]] = [
            [0, 0],
            [1, 0],
        ]
        let hits = try search(query: [0, 0], rows: rows, k: 10, metric: .l2)
        XCTAssertEqual(hits.count, 2)
        try assertMatchesBaseline(query: [0, 0], rows: rows, k: 10, metric: .l2)
    }

    func testIdenticalVectorsTieBreakByRow() throws {
        let rows: [[Float]] = [
            [1, 0],
            [1, 0],
            [1, 0],
        ]
        let hits = try search(query: [1, 0], rows: rows, k: 3, metric: .l2)
        XCTAssertEqual(hits.map(\.row), [0, 1, 2])
        XCTAssertTrue(hits.allSatisfy { abs($0.distance) < accuracy })
    }

    func testAllMetricsMatchBaseline() throws {
        let query: [Float] = [1, 0, 0]
        let rows: [[Float]] = [
            [1, 0, 0],
            [0, 1, 0],
            [0.5, 0.5, 0],
            [0, 0, 0],
            [-1, 0, 0],
        ]
        for metric in DistanceMetric.allCases {
            for k in 1...rows.count {
                try assertMatchesBaseline(query: query, rows: rows, k: k, metric: metric)
            }
        }
    }

    func testIsLiveSkipsRows() throws {
        let rows: [[Float]] = [
            [0, 0],   // 0 live
            [10, 0],  // 1 dead — would be far
            [1, 0],   // 2 live nearest after origin
        ]
        let hits = try search(
            query: [0, 0],
            rows: rows,
            k: 2,
            metric: .l2,
            isLive: { $0 != 1 }
        )
        XCTAssertEqual(hits.map(\.row), [0, 2])
        try assertMatchesBaseline(
            query: [0, 0],
            rows: rows,
            k: 2,
            metric: .l2,
            isLive: { $0 != 1 }
        )
    }

    func testInvalidKThrows() {
        XCTAssertThrowsError(
            try [Float]([0, 0]).withUnsafeBufferPointer { db in
                try FlatIndex.search(
                    query: [0, 0],
                    database: db,
                    count: 1,
                    dim: 2,
                    k: 0,
                    metric: .l2,
                    compute: compute
                )
            }
        ) { error in
            guard case VectorSwiftError.invalidArgument = error else {
                return XCTFail("Expected invalidArgument, got \(error)")
            }
        }
    }

    func testResultsSortedNondecreasingDistance() throws {
        var rng = FlatIndexTestRNG(seed: 7)
        let dim = 8
        let n = 50
        let query = (0..<dim).map { _ in rng.nextFloat() }
        let rows: [[Float]] = (0..<n).map { _ in
            (0..<dim).map { _ in rng.nextFloat() }
        }
        let hits = try search(query: query, rows: rows, k: 10, metric: .l2Squared)
        for i in 1..<hits.count {
            let prev = hits[i - 1]
            let cur = hits[i]
            XCTAssertLessThanOrEqual(prev.distance, cur.distance)
            if prev.distance == cur.distance {
                XCTAssertLessThan(prev.row, cur.row)
            }
        }
        try assertMatchesBaseline(query: query, rows: rows, k: 10, metric: .l2Squared)
    }
}

private struct FlatIndexTestRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24) * 2 - 1
    }
}
