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
- **Seal**: `checkpoint()` / size thresholds flush the mutable overlay to a new
  sealed segment (`VECTORS.bin` / `IDS.bin` / `PAYLOAD.bin` / `TOMBSTONES.bin` +
  `SEGMENT_META.json`), atomically append it to `MANIFEST.json`, and reclaim the WAL
- **Search** merges exact top-k across sealed segments + the mutable overlay
  (last write wins; tombstones hide deleted sealed ids). Compaction is not finished yet

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

Checks are **separate**. Do not use a bare `swift build` (that also builds the example).

| Script | What |
| --- | --- |
| `./scripts/test.sh` | **Unit tests only** (`VectorSwiftTests`). **Required before every commit.** |
| `./scripts/build.sh` | Library target `VectorSwift` only (debug). `--release` adds a release build. Does **not** build the example. |
| `./scripts/example.sh` | Sample executable `VectorSwiftExample` only. |
| `./scripts/check.sh` | Local convenience: build `--release`, then tests, then example (same three scripts, in order). |

```bash
./scripts/test.sh              # mandatory before commit
./scripts/build.sh --release   # library only
./scripts/example.sh           # optional local / CI example job
```

### Continuous integration

Pull requests and pushes to `main` run [`.github/workflows/ci.yml`](.github/workflows/ci.yml) as **independent** jobs:

| Job | Runner | Script |
| --- | --- | --- |
| Build (macOS) | `macos-15` + Xcode | `./scripts/build.sh --release` |
| Build (Linux) | `ubuntu-latest` + Swift 5.10 | `./scripts/build.sh --release` (system `libz`) |
| Test (Linux CPU) | `ubuntu-latest` + Swift 5.10 | `./scripts/test.sh` |
| Test (macOS / MLX) | `macos-15` + Xcode | `./scripts/test.sh` (+ MLX target when `VectorSwiftComputeMLX` exists) |
| Example (macOS / Linux) | same runners | `./scripts/example.sh` |
| **macOS (build + test)** | aggregator | Green if all macOS jobs succeeded |
| **Linux (build + test)** | aggregator | Green if all Linux jobs succeeded |
| **CI** | aggregator | Green if both OS aggregators succeeded |

Merge when required checks are green. Existing branch protection still uses **macOS (build + test)** and **Linux (build + test)**; those names are posted by the aggregators. You can later require only **CI**.

Unit tests are a commit gate locally, not only a merge gate.

#### GitHub: required checks for `main`

**Settings → Branches** (or **Rules → Rulesets**), require a PR, then require status checks:

- Keep (current): `macOS (build + test)` and `Linux (build + test)` — these now report again.
- Optional later: add `CI` and drop the two OS names so you only maintain one required check.

Check names appear in the picker after this workflow has run once.

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
