import VectorSwift

@main
struct QuickStart {
    static func main() async throws {
        let db = try await Database.open()

        try await db.createCollection(
            CollectionConfig(
                name: "documents",
                dimension: 3,
                metric: .cosine,
                normalizeVectors: true
            )
        )

        let documents = try await db.collection(name: "documents")
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
    }
}
