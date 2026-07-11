import XCTest
@testable import VectorSwift

final class PackageSmokeTests: XCTestCase {
    func testPackageSmokeLinksModuleGraph() {
        XCTAssertEqual(VectorSwift.name, "VectorSwift")
        let modules = VectorSwift.linkedModules
        XCTAssertTrue(modules.contains("VectorSwiftCore"))
        XCTAssertTrue(modules.contains("VectorSwiftCompute"))
        XCTAssertTrue(modules.contains("VectorSwiftIndex"))
        XCTAssertTrue(modules.contains("VectorSwiftQuery"))
        XCTAssertTrue(modules.contains("VectorSwift"))
        XCTAssertEqual(modules.count, 5)
    }
}
