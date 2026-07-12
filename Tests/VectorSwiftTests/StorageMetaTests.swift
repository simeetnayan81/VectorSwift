import XCTest
import VectorSwift
import VectorSwiftStorage

final class StorageMetaTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreateListSurvivesReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let db = try await Database.open(
                path: root,
                config: DatabaseConfig(durability: .strict, compute: .cpu)
            )
            try await db.createCollection(CollectionConfig(
                name: "docs",
                dimension: 4,
                metric: .cosine,
                normalizeVectors: true
            ))
            try await db.createCollection(CollectionConfig(
                name: "images",
                dimension: 8,
                metric: .l2
            ))
            let names = try await db.listCollections()
            XCTAssertEqual(names, ["docs", "images"])
            try await db.close()
        }

        let layout = DatabaseLayout(root: root)
        XCTAssertTrue(JSONFileStore.exists(layout.dbMeta))
        XCTAssertTrue(JSONFileStore.exists(layout.catalog))
        XCTAssertTrue(JSONFileStore.exists(layout.collectionMeta(name: "docs")))

        let reopened = try await Database.open(path: root)
        let names = try await reopened.listCollections()
        XCTAssertEqual(names, ["docs", "images"])

        let docs = try await reopened.collection(name: "docs")
        let docsConfig = await docs.config
        XCTAssertEqual(docsConfig.dimension, 4)
        XCTAssertEqual(docsConfig.metric, .cosine)
        XCTAssertTrue(docsConfig.normalizeVectors)

        // Points are not durable yet — reopened collection is empty.
        let count = await docs.count()
        XCTAssertEqual(count, 0)

        let dbConfig = await reopened.config
        XCTAssertEqual(dbConfig.durability, .strict)
        XCTAssertEqual(dbConfig.compute, .cpu)

        try await reopened.close()
    }

    func testDropPersistsAcrossReopen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try await Database.open(path: root)
        try await db.createCollection(CollectionConfig(name: "a", dimension: 2, metric: .l2))
        try await db.createCollection(CollectionConfig(name: "b", dimension: 2, metric: .l2))
        try await db.dropCollection(name: "a")
        try await db.close()

        let reopened = try await Database.open(path: root)
        let names = try await reopened.listCollections()
        XCTAssertEqual(names, ["b"])
        try await reopened.close()
    }

    func testCorruptDBMetaThrows() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = DatabaseLayout(root: root)
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: layout.dbMeta)

        do {
            _ = try await Database.open(path: root)
            XCTFail("expected corruption error")
        } catch let error as VectorSwiftError {
            guard case .corrupted(let path, _) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(path.contains("DB_META"))
        }
    }

    func testInMemoryModeStillWorksWithoutPath() async throws {
        let db = try await Database.open()
        try await db.createCollection(CollectionConfig(name: "mem", dimension: 2, metric: .l2))
        let col = try await db.collection(name: "mem")
        try await col.upsert([Point(id: "x", vector: [1, 0])])
        let n = await col.count()
        XCTAssertEqual(n, 1)
        try await db.close()
    }

    func testAtomicMetaRoundTrip() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.json")
        let doc = CatalogDocument(collections: ["a": "collections/a"])
        try JSONFileStore.writeAtomic(doc, to: url)
        let loaded = try JSONFileStore.read(CatalogDocument.self, from: url)
        XCTAssertEqual(loaded, doc)
    }
}
