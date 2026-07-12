# VectorSwift

Swift library for in-process vector storage and nearest-neighbor search.

Collections hold dense vectors with optional metadata. Search returns the closest
points under a chosen distance metric. The library is designed for embedding use
in applications and Swift services.

## Status

- **In-memory** storage (data does not persist across process restarts)
- **Exact** search (`flat` index)
- Multi-collection `Database` API
- Metrics: Euclidean (L2 / L2²), inner product, cosine

Approximate indexes, on-disk durability, metadata filters, and GPU acceleration
are not available yet.

## Requirements

- macOS with full **Xcode** (not Command Line Tools alone)
- Swift 5.10+

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Build & test

```bash
swift build
swift test
```

## Example

Run the sample program:

```bash
swift run VectorSwiftExample
```

Source: [`Examples/QuickStart`](Examples/QuickStart).

```swift
import VectorSwift

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
    Point(id: "intro", vector: [1, 0, 0], payload: ["title": .string("Introduction")]),
    Point(id: "guide", vector: [0.9, 0.1, 0], payload: ["title": .string("User Guide")]),
    Point(id: "api", vector: [0, 1, 0], payload: ["title": .string("API Reference")]),
])

let results = try await documents.search(
    SearchRequest(vector: [1, 0.05, 0], k: 2, withPayload: true)
)

for hit in results {
    print(hit.id, hit.distance, hit.payload as Any)
}

try await db.close()
```

## Notes

| Topic | Behavior |
| --- | --- |
| Index types | Only `flat` is supported. Creating a collection with `hnsw` fails. |
| Distance | Always **smaller = closer** (inner product is negated for ranking). |
| Filters | `SearchRequest.filter` is stored on the request type but not applied. |
| Path | `Database.open(path:)` may create a directory; vectors are not loaded or saved yet. |
| Import | Use `import VectorSwift`. |

## License

See [LICENSE](LICENSE).
