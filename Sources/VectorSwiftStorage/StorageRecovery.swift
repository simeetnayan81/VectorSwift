import Foundation

/// Open-time reclaim and WAL replay helpers (design §7.5–§7.6).
///
/// Readers trust only `MANIFEST.json`. Segment directories not listed there are
/// leftovers from a seal that never published; leftover `*.tmp` files are
/// unpublished atomic-write attempts. Neither is loaded.
public enum StorageRecovery {
    /// Deletes numeric `segments/{id}/` directories whose id is not in `liveSegmentIds`.
    ///
    /// Non-numeric names are left untouched. Missing `segmentsDirectory` is a no-op.
    /// Individual delete failures are ignored so a sticky orphan cannot block open.
    ///
    /// - Returns: Segment ids whose directories were removed.
    @discardableResult
    public static func removeUnlistedSegmentDirectories(
        segmentsDirectory: URL,
        liveSegmentIds: Set<UInt64>
    ) -> [UInt64] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: segmentsDirectory.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: segmentsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var removed: [UInt64] = []
        for url in entries {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            guard let id = UInt64(url.lastPathComponent) else { continue }
            guard !liveSegmentIds.contains(id) else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(id)
            } catch {
                continue
            }
        }
        return removed.sorted()
    }

    /// Deletes leftover `*.tmp` files directly under `directory` (non-recursive).
    ///
    /// Missing directory is a no-op. Individual delete failures are ignored.
    ///
    /// - Returns: URLs that were removed.
    @discardableResult
    public static func removeLeftoverTemporaryFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var removed: [URL] = []
        for url in entries {
            guard url.pathExtension == "tmp" else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                continue
            }
        }
        return removed
    }

    /// Index of the first WAL record that must be replayed after loading published segments.
    ///
    /// Records through the last `seal_segment` / `seal_segment_v2` whose id is in
    /// `publishedSegmentIds` are already materialized on disk. An unpublished seal
    /// (files never made it into MANIFEST) does not advance the start index, so
    /// preceding upserts/deletes still replay.
    public static func replayStartIndex(
        records: [WALRecord],
        publishedSegmentIds: Set<UInt64>
    ) -> Int {
        var lastPublishedSeal = -1
        for (index, record) in records.enumerated() {
            switch record {
            case .sealSegment(let segmentId) where publishedSegmentIds.contains(segmentId):
                lastPublishedSeal = index
            case .sealSegmentV2(let payload) where publishedSegmentIds.contains(payload.segmentId):
                lastPublishedSeal = index
            default:
                break
            }
        }
        return lastPublishedSeal + 1
    }

    /// Smallest next segment id that cannot collide with a published segment.
    public static func repairedNextSegmentId(
        persisted: UInt64,
        publishedSegmentIds: [UInt64]
    ) -> UInt64 {
        let floor = (publishedSegmentIds.max() ?? 0) + 1
        return max(persisted, floor)
    }
}
