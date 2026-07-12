import Foundation
import VectorSwiftCore

/// Atomic JSON read/write helpers for database meta files.
public enum JSONFileStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Writes `value` to `url` via a temporary file + rename for crash safety.
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
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temp, to: url)
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to write \(url.path): \(error)")
        }
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
}
