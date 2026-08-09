import Foundation
import VectorSwiftCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Atomic JSON read/write helpers for database meta files.
///
/// Publish protocol (design §7.5): write `*.tmp` → fsync → POSIX `rename` over the
/// destination. Readers trust only the final filename; leftover tmp files are ignored.
public enum JSONFileStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Writes `value` to `url` via a temporary file + rename for crash safety.
    ///
    /// Does **not** unlink the destination before rename. `rename(2)` replaces an
    /// existing file atomically on APFS / ext4, so a crash cannot leave the
    /// canonical path missing.
    public static func writeAtomic<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw VectorSwiftError.io("Failed to encode JSON for \(url.path): \(error)")
        }

        let temp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: [])
        } catch {
            throw VectorSwiftError.io("Failed to write \(temp.path): \(error)")
        }

        do {
            try fsyncFile(at: temp)
            try renameOver(from: temp, to: url)
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to publish \(url.path): \(error)")
        }

        fsyncDirectoryBestEffort(directory)
    }

    /// Reads and decodes JSON from `url`.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VectorSwiftError.io("Failed to read \(url.path): \(error)")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw VectorSwiftError.corrupted(
                path: url.path,
                reason: "Invalid JSON: \(error)"
            )
        }
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Internals

    private static func fsyncFile(at url: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to fsync \(url.path): \(error)")
        }
    }

    /// POSIX rename over `dest`, replacing it if present. Never unlinks first.
    private static func renameOver(from src: URL, to dest: URL) throws {
        try src.withUnsafeFileSystemRepresentation { srcPtr in
            guard let srcPtr else {
                throw VectorSwiftError.io("Invalid source path \(src.path)")
            }
            try dest.withUnsafeFileSystemRepresentation { destPtr in
                guard let destPtr else {
                    throw VectorSwiftError.io("Invalid dest path \(dest.path)")
                }
                if rename(srcPtr, destPtr) != 0 {
                    let err = errno
                    throw VectorSwiftError.io(
                        "Failed to rename \(src.path) → \(dest.path): \(String(cString: strerror(err)))"
                    )
                }
            }
        }
    }

    /// Best-effort directory fsync after rename (ignored on failure).
    private static func fsyncDirectoryBestEffort(_ directory: URL) {
        directory.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return }
            let fd = open(ptr, O_RDONLY)
            guard fd >= 0 else { return }
            _ = fsync(fd)
            close(fd)
        }
    }
}
