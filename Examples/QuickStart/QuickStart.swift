import Foundation
import VectorSwift

/// Sample app: open a database directory, search, then reopen to show durable points via WAL.
@main
struct QuickStart {
    static func main() async throws {
        // Database root directory (the {root} in docs). Meta + WAL live under this path.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSwift-Example-DB", isDirectory: true)

        print("Database root: \(root.path)")
        print("Layout:")
        print("  \(root.path)/DB_META.json")
        print("  \(root.path)/CATALOG.json")
        print("  \(root.path)/collections/<name>/COLL_META.json")
        print("  \(root.path)/collections/<name>/wal/wal.log")
        print("")

        // First open: creates the directory and writes meta when collections are created.
        var db = try await Database.open(
            path: root,
            config: DatabaseConfig(durability: .strict, compute: .cpu)
        )

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

        // Upserts append to the collection WAL so they survive reopen.
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

        // Reopen the same root: catalog meta + WAL replay restore points and payloads.
        db = try await Database.open(path: root)
        let names = try await db.listCollections()
        print("")
        print("After reopen, collections on disk: \(names)")
        let reopened = try await db.collection(name: collectionName)
        let liveCount = await reopened.count()
        print("Live points after reopen (via WAL): \(liveCount)")
        let restored = await reopened.get(ids: ["intro"], withVector: false)
        if let point = restored.first, case .string(let title)? = point.payload["title"] {
            print("get(\"intro\") after reopen: title=\(title)")
        }
        let again = try await reopened.search(
            SearchRequest(vector: [1, 0.05, 0], k: 1, withPayload: true)
        )
        if let top = again.first {
            let title: String
            if case .string(let value)? = top.payload?["title"] {
                title = value
            } else {
                title = "(untitled)"
            }
            print("Top hit after reopen: \(top.id) distance=\(top.distance) title=\(title)")
        }
        try await db.close()

        print("")
        print("Inspect files with: ls -R \"\(root.path)\"")
    }
}
