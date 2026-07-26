import Foundation
import VectorSwiftCore

/// Append-only write-ahead log file (`wal/wal.log`, design §7.3).
///
/// ## Lifecycle
/// - On open/replay: scan valid frames; **truncate** an incomplete trailing frame.
/// - CRC failures and malformed complete frames are **corruption** (fail closed).
/// - Missing file is treated as an empty log.
///
/// ## Concurrency
/// Intended to be owned by a single `Collection` actor. Not safe for concurrent
/// writers from multiple threads without external serialization.
public struct WriteAheadLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    // MARK: - Append

    /// Encodes and appends `record` to the log.
    ///
    /// - Parameter sync: When true, `fsync`s the file after the write (strict durability).
    public func append(_ record: WALRecord, sync: Bool) throws {
        let frame = try WALCodec.encodeFrame(record)
        try ensureParentDirectory()

        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: frame)
            if sync {
                try handle.synchronize()
            }
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to append WAL at \(url.path): \(error)")
        }
    }

    /// Appends multiple records in order, optionally fsyncing once at the end.
    public func append(contentsOf records: [WALRecord], sync: Bool) throws {
        guard !records.isEmpty else { return }
        try ensureParentDirectory()

        var blob = Data()
        for record in records {
            blob.append(try WALCodec.encodeFrame(record))
        }

        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: blob)
            if sync {
                try handle.synchronize()
            }
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to append WAL batch at \(url.path): \(error)")
        }
    }

    /// Forces buffered WAL data to stable storage when the file exists.
    public func synchronize() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            throw VectorSwiftError.io("Failed to fsync WAL at \(url.path): \(error)")
        }
    }

    // MARK: - Read / recover

    /// Reads all complete valid records. Truncates an incomplete tail when requested.
    ///
    /// - Parameter truncateIncompleteTail: When true (default), trims the file to the
    ///   end of the last good record if a partial frame is found at EOF.
    /// - Returns: Decoded records in append order.
    public func readAllValidRecords(truncateIncompleteTail: Bool = true) throws -> [WALRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VectorSwiftError.io("Failed to read WAL at \(url.path): \(error)")
        }

        if data.isEmpty {
            return []
        }

        var records: [WALRecord] = []
        var offset = 0
        while offset < data.count {
            let result = try WALCodec.readFrame(from: data, at: offset, path: url.path)
            switch result {
            case .record(let record, let nextOffset):
                records.append(record)
                offset = nextOffset
            case .incompleteTail:
                if truncateIncompleteTail {
                    try truncate(to: offset)
                }
                return records
            }
        }
        return records
    }

    /// Truncates the log file to `length` bytes (used after detecting a torn tail).
    public func truncate(to length: Int) throws {
        guard length >= 0 else {
            throw VectorSwiftError.invalidArgument("WAL truncate length must be >= 0")
        }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                if length == 0 { return }
                throw VectorSwiftError.io("Cannot truncate missing WAL at \(url.path)")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(length))
            try handle.synchronize()
        } catch let error as VectorSwiftError {
            throw error
        } catch {
            throw VectorSwiftError.io("Failed to truncate WAL at \(url.path): \(error)")
        }
    }

    // MARK: - Internals

    private func ensureParentDirectory() throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw VectorSwiftError.io("Failed to create WAL directory \(dir.path): \(error)")
        }
    }
}
