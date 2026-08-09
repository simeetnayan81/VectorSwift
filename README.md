# VectorSwift

Swift library for in-process vector storage and nearest-neighbor search.

Collections hold dense vectors with optional metadata. Search returns the closest
points under a chosen distance metric. The library is designed for embedding use
in applications and Swift services.

## Status

- Multi-collection `Database` API with **exact** (`flat`) search
- Metrics: Euclidean (L2 / L2²), inner product, cosine
- Optional on-disk root when you open with a directory path:
  catalog metadata (`DB_META.json`, `CATALOG.json`, `collections/<name>/COLL_META.json`)
  plus per-collection **WAL** (`wal/wal.log`) so upserts/deletes survive reopen
- **Durability levels** (`relaxed` / `balanced` default / `strict`): control when the WAL is fsynced; `checkpoint()` and clean `close()` fsync for all levels
- **Seal**: `checkpoint()` / size thresholds flush live points to sealed segment files
  (`VECTORS.bin` / `IDS.bin` / `PAYLOAD.bin` + `SEGMENT_META.json`), publish `MANIFEST.json`,
  and reclaim the WAL; reopen loads segments then replays any post-seal WAL
- Multi-segment search merge and compaction not finished yet

Approximate indexes, metadata filters, and GPU acceleration are not available yet.

## Requirements

- macOS with full **Xcode** (not Command Line Tools alone), **or** Linux with
  Swift 5.10+ and zlib development headers (`libz-dev` / `zlib-devel`) for CRC-32
- Swift 5.10+
- On Linux: `pkg-config` recommended so SwiftPM can resolve the `CZlib` system library

```bash
# macOS — point at full Xcode so XCTest is available
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Build & test

Preferred (same checks as CI before merge):

```bash
./scripts/check.sh
```

Or individually:

```bash
./scripts/test.sh          # swift test
swift build
swift test
```

### Continuous integration

Pull requests and pushes to `main` run [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

| Job | Runner | What runs |
| --- | --- | --- |
| macOS | `macos-15` + Xcode | `./scripts/check.sh` (debug/release build + tests + example) |
| Linux | `ubuntu-latest` + Swift 5.10 | Same script (CPU path; links system `libz`) |

Merge only when both jobs are green.

## Example

Run the sample program:

```bash
swift run VectorSwiftExample
```

Source: [`Examples/QuickStart`](Examples/QuickStart).

It opens a **database root directory** (your on-disk `{root}`), creates a collection,
runs a search, then reopens the same path so you can see that **catalog meta and
points** (via WAL) survive.

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

// Reopen the same root: collection list/config and points reload from disk (WAL).
let again = try await Database.open(path: root)
print(try await again.listCollections())
let reopened = try await again.collection(name: "documents")
print(await reopened.count()) // 3
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
      wal/
        wal.log
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
