import Foundation
import VectorSwift

/// Sample app: open a database directory, search, then reopen to show catalog meta on disk.
@main
struct QuickStart {
    static func main() async throws {
        // Database root directory (the {root} in docs). Meta files live under this path.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-Example-DB", isDirectory: true)

        print("Database root: \(root.path)")
        print("Layout:")
        print("  \(root.path)/DB_META.json")
        print("  \(root.path)/CATALOG.json")
        print("  \(root.path)/collections/<name>/COLL_META.json")
        print("")

        // First open: creates the directory and writes meta when collections are created.
        var db = try await Database.open(path: root)

        let collectionName = "documents"
        let existing = try await db.listCollections()
        if !existing.contains(collectionName) {
            try await db.createCollection(
                CollectionConfig(
                    name: collectionName,
                    dimension: 3,
                    metric: .cosine,
                    normalizeVectors: true
                )
            )
            print("Created collection \"\(collectionName)\".")
        } else {
            print("Collection \"\(collectionName)\" already registered on disk.")
        }

        let documents = try await db.collection(name: collectionName)

        // Point data is still in-memory only for this open session.
        try await documents.upsert([
            Point(
                id: "intro",
                vector: [1, 0, 0],
                payload: ["title": .string("Introduction")]
            ),
            Point(
                id: "guide",
                vector: [0.9, 0.1, 0],
                payload: ["title": .string("User Guide")]
            ),
            Point(
                id: "api",
                vector: [0, 1, 0],
                payload: ["title": .string("API Reference")]
            ),
        ])

        let results = try await documents.search(
            SearchRequest(
                vector: [1, 0.05, 0],
                k: 2,
                withPayload: true
            )
        )

        print("Nearest documents:")
        for hit in results {
            let title: String
            if case .string(let value)? = hit.payload?["title"] {
                title = value
            } else {
                title = "(untitled)"
            }
            print("  \(hit.id)  distance=\(hit.distance)  title=\(title)")
        }

        try await db.close()

        // Reopen the same root: collection definitions come back from disk meta.
        // Upserted vectors do not (not written to segments yet).
        db = try await Database.open(path: root)
        let names = try await db.listCollections()
        print("")
        print("After reopen, collections on disk: \(names)")
        let reopened = try await db.collection(name: collectionName)
        let liveCount = await reopened.count()
        print("Live points after reopen (expect 0 until vector durability): \(liveCount)")
        try await db.close()

        print("")
        print("Inspect files with: ls -R \"\(root.path)\"")
    }
}
