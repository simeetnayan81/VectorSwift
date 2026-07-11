import XCTest
import VectorSwift

final class DistanceTests: XCTestCase {
    private let accuracy: Float = 1e-5

    // MARK: - L2 / L2 squared

    func testL2AndL2Squared_3_4_5_triangle() throws {
        let a: [Float] = [0, 0]
        let b: [Float] = [3, 4]

        let l2sq = try VectorDistance.distance(a, b, metric: .l2Squared)
        let l2 = try VectorDistance.distance(a, b, metric: .l2)

        XCTAssertEqual(l2sq, 25, accuracy: accuracy)
        XCTAssertEqual(l2, 5, accuracy: accuracy)
        XCTAssertEqual(l2 * l2, l2sq, accuracy: accuracy)
    }

    func testL2IdenticalVectorsAreZero() throws {
        let v: [Float] = [1.5, -2, 0.25]
        XCTAssertEqual(try VectorDistance.distance(v, v, metric: .l2), 0, accuracy: accuracy)
        XCTAssertEqual(try VectorDistance.distance(v, v, metric: .l2Squared), 0, accuracy: accuracy)
    }

    // MARK: - Inner product (negated so smaller = closer)

    func testInnerProduct_identicalUnitAxis() throws {
        let a: [Float] = [1, 0]
        let b: [Float] = [1, 0]
        // dot = 1 → distance = -1
        XCTAssertEqual(try VectorDistance.distance(a, b, metric: .innerProduct), -1, accuracy: accuracy)
    }

    func testInnerProduct_oppositeAxisIsFartherThanAligned() throws {
        let q: [Float] = [1, 0]
        let same = try VectorDistance.distance(q, [1, 0], metric: .innerProduct)
        let opposite = try VectorDistance.distance(q, [-1, 0], metric: .innerProduct)
        // same: -1, opposite: -(-1) = +1  → opposite has larger distance
        XCTAssertEqual(same, -1, accuracy: accuracy)
        XCTAssertEqual(opposite, 1, accuracy: accuracy)
        XCTAssertLessThan(same, opposite)
    }

    // MARK: - Cosine

    func testCosine_identicalDirection() throws {
        let a: [Float] = [1, 0]
        let b: [Float] = [1, 0]
        XCTAssertEqual(try VectorDistance.distance(a, b, metric: .cosine), 0, accuracy: accuracy)
    }

    func testCosine_orthogonal() throws {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(try VectorDistance.distance(a, b, metric: .cosine), 1, accuracy: accuracy)
    }

    func testCosine_zeroNormTreatedAsDistanceOne() throws {
        let zero: [Float] = [0, 0]
        let other: [Float] = [1, 0]
        XCTAssertEqual(try VectorDistance.distance(zero, other, metric: .cosine), 1, accuracy: accuracy)
        XCTAssertEqual(try VectorDistance.distance(other, zero, metric: .cosine), 1, accuracy: accuracy)
        XCTAssertEqual(try VectorDistance.distance(zero, zero, metric: .cosine), 1, accuracy: accuracy)
    }

    func testCosine_scaledSameDirection() throws {
        // [2,0] and [4,0] same direction → cos = 1 → distance 0
        let a: [Float] = [2, 0]
        let b: [Float] = [4, 0]
        XCTAssertEqual(try VectorDistance.distance(a, b, metric: .cosine), 0, accuracy: accuracy)
    }

    // MARK: - Validation

    func testMismatchedLengthsThrow() {
        let a: [Float] = [1, 2]
        let b: [Float] = [1, 2, 3]
        XCTAssertThrowsError(try VectorDistance.distance(a, b, metric: .l2)) { error in
            guard case VectorSwiftError.invalidArgument = error else {
                return XCTFail("Expected invalidArgument, got \(error)")
            }
        }
    }

    // MARK: - Empty vectors

    func testEmptyVectors_l2AndIP() throws {
        let empty: [Float] = []
        XCTAssertEqual(try VectorDistance.distance(empty, empty, metric: .l2), 0, accuracy: accuracy)
        XCTAssertEqual(try VectorDistance.distance(empty, empty, metric: .l2Squared), 0, accuracy: accuracy)
        XCTAssertEqual(try VectorDistance.distance(empty, empty, metric: .innerProduct), 0, accuracy: accuracy)
        // empty ⇒ zero norm ⇒ cosine distance 1
        XCTAssertEqual(try VectorDistance.distance(empty, empty, metric: .cosine), 1, accuracy: accuracy)
    }
}
