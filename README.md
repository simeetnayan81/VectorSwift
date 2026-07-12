# VectorSwift

Swift library for in-process vector storage and nearest-neighbor search.

Collections hold dense vectors with optional metadata. Search returns the closest
points under a chosen distance metric. The library is designed for embedding use
in applications and Swift services.

## Status

- Multi-collection `Database` API with **exact** (`flat`) search
- Metrics: Euclidean (L2 / L2²), inner product, cosine
- Optional on-disk **catalog metadata** when you open with a directory path
  (`DB_META.json`, `CATALOG.json`, `collections/<name>/COLL_META.json`)
- **Point data** is still in-memory only (not written to segments/WAL yet)

Approximate indexes, full durable vectors, metadata filters, and GPU acceleration
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

It opens a **database root directory** (your on-disk `{root}`), creates a collection,
runs a search, then reopens the same path so you can see that **catalog meta**
survives while **vectors** do not yet.

```swift
import Foundation
import VectorSwift

// {root} — directory that will hold DB_META.json, CATALOG.json, collections/
let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("VectorSwift-Example-DB", isDirectory: true)

let db = try await Database.open(path: root)

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

// Reopen the same root: collection list/config reload from disk; points are empty for now.
let again = try await Database.open(path: root)
print(try await again.listCollections())
try await again.close()
```

On disk after the first run:

```
{root}/
  DB_META.json
  CATALOG.json
  collections/
    documents/
      COLL_META.json
```

## Notes

| Topic | Behavior |
| --- | --- |
| Index types | Only `flat` is supported. Creating a collection with `hnsw` fails. |
| Distance | Always **smaller = closer** (inner product is negated for ranking). |
| Filters | `SearchRequest.filter` is stored on the request type but not applied. |
| Path | `Database.open(path:)` uses that directory as the DB root for catalog meta. |
| Import | Use `import VectorSwift`. |

## License

See [LICENSE](LICENSE).
