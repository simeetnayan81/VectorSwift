import XCTest
import VectorSwift

final class DatabaseTests: XCTestCase {

    func testTwoCollectionsUpsertSearchAndDrop() async throws {
        let db = try await Database.open()

        try await db.createCollection(CollectionConfig(
            name: "docs",
            dimension: 2,
            metric: .l2
        ))
        try await db.createCollection(CollectionConfig(
            name: "images",
            dimension: 3,
            metric: .cosine,
            normalizeVectors: true
        ))

        let docs = try await db.collection(name: "docs")
        let images = try await db.collection(name: "images")

        try await docs.upsert([
            Point(id: "d1", vector: [0, 0]),
            Point(id: "d2", vector: [1, 0]),
        ])
        try await images.upsert([
            Point(id: "i1", vector: [2, 0, 0]),
            Point(id: "i2", vector: [0, 2, 0]),
        ])

        let docHits = try await docs.search(SearchRequest(vector: [0, 0], k: 1))
        XCTAssertEqual(docHits[0].id, "d1")

        let imageHits = try await images.search(SearchRequest(vector: [1, 0, 0], k: 1))
        XCTAssertEqual(imageHits[0].id, "i1")

        // Isolation: docs query shape must not be used on images without matching dim
        do {
            _ = try await images.search(SearchRequest(vector: [0, 0], k: 1))
            XCTFail("expected dimension error")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .invalidDimension(expected: 3, actual: 2))
        }

        try await db.dropCollection(name: "images")
        let names = try await db.listCollections()
        XCTAssertEqual(names, ["docs"])

        do {
            _ = try await db.collection(name: "images")
            XCTFail("expected not found")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .collectionNotFound("images"))
        }

        try await db.close()
    }

    func testListCollectionsSorted() async throws {
        let db = try await Database.open()
        try await db.createCollection(CollectionConfig(name: "zeta", dimension: 2, metric: .l2))
        try await db.createCollection(CollectionConfig(name: "alpha", dimension: 2, metric: .l2))
        let names = try await db.listCollections()
        XCTAssertEqual(names, ["alpha", "zeta"])
        try await db.close()
    }

    func testDuplicateCreateThrows() async throws {
        let db = try await Database.open()
        let config = CollectionConfig(name: "docs", dimension: 2, metric: .l2)
        try await db.createCollection(config)
        do {
            try await db.createCollection(config)
            XCTFail("expected exists")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .collectionExists("docs"))
        }
        try await db.close()
    }

    func testDropMissingThrows() async throws {
        let db = try await Database.open()
        do {
            try await db.dropCollection(name: "nope")
            XCTFail("expected not found")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .collectionNotFound("nope"))
        }
        try await db.close()
    }

    func testCloseThenOpsThrowAndSecondCloseThrows() async throws {
        let db = try await Database.open()
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.close()

        do {
            try await db.close()
            XCTFail("expected closed")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .closed)
        }

        do {
            _ = try await db.listCollections()
            XCTFail("expected closed")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .closed)
        }

        do {
            try await db.createCollection(CollectionConfig(name: "x", dimension: 2, metric: .l2))
            XCTFail("expected closed")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testOpenWithPathCreatesDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-DB-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let db = try await Database.open(path: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let stored = await db.storagePath
        XCTAssertEqual(stored?.path, dir.path)

        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "docs")
        try await col.upsert([Point(id: "a", vector: [1, 0])])
        let n = await col.count()
        XCTAssertEqual(n, 1)

        try await db.close()
    }

    func testCheckpoint() async throws {
        let db = try await Database.open()
        try await db.createCollection(CollectionConfig(name: "docs", dimension: 2, metric: .l2))
        try await db.checkpoint()
        try await db.close()
    }

    func testMLXPreferenceUnavailable() async throws {
        do {
            _ = try await Database.open(config: DatabaseConfig(compute: .mlx))
            XCTFail("expected backend unavailable")
        } catch let error as VectorSwiftError {
            XCTAssertEqual(error, .backendUnavailable("mlx"))
        }
    }

    func testConfigExposed() async throws {
        let db = try await Database.open(config: DatabaseConfig(durability: .strict, compute: .cpu))
        let cfg = await db.config
        XCTAssertEqual(cfg.durability, .strict)
        XCTAssertEqual(cfg.compute, .cpu)
        try await db.close()
    }
}
