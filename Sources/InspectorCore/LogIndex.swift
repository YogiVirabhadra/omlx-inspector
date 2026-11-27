import Foundation
import CryptoKit

public struct IndexUpdate: Sendable {
    public var snapshot: LogSnapshot
    public var reset: Bool
    public var recovery: String?
}

/// A streaming, in-memory offset index. Source bodies are not retained in the index.
/// The trailing record is interpreted provisionally and replayed when its boundary grows.
public struct LogIndex: Sendable {
    public let url: URL
    public private(set) var bytesRead: UInt64 = 0
    private var size: UInt64 = 0
    private var inode: UInt64 = 0
    private var modified: Date = .distantPast
    private var generation = UUID().uuidString
    private var head = Data(), tail = Data()
    private var builder = EvidenceBuilder()
    private var buffer = Data(), recordBytes = Data()
    private var current: LogRecord?
    private var records: [IndexedLogRecord] = []
    private var offset: UInt64 = 0
    private var line = 1, count = 0
    private var lastSnapshot: LogSnapshot?

    public init(url: URL) { self.url = url }

    public mutating func refresh() throws -> IndexUpdate? {
        let (newSize, newInode, newModified) = try LogReader.metadata(url)
        if lastSnapshot != nil, newSize == size, newInode == inode, newModified == modified { return nil }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        func read(_ at: UInt64, _ length: Int) throws -> Data {
            try file.seek(toOffset: at)
            return try file.read(upToCount: length) ?? Data()
        }
        var reason: String?
        if lastSnapshot != nil {
            if newInode != inode { reason = "Log replaced or rotated. A new source generation was indexed." }
            else if newSize < size { reason = "Log truncated. A new source generation was indexed." }
            else if try newSize == size || read(0, head.count) != head || read(size - UInt64(tail.count), tail.count) != tail {
                reason = "Log rewritten. A new source generation was indexed."
            }
        }
        // Commit only after a successful complete read; cancellation/errors retain the old index.
        var next = reason == nil ? self : LogIndex(url: url)
        next.inode = newInode
        try file.seek(toOffset: next.size)
        var readOffset = next.size
        while readOffset < newSize {
            try autoreleasepool {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: Int(min(65536, newSize - readOffset))) ?? Data()
                guard !chunk.isEmpty else { throw InspectorError.invalid("The source changed while indexing. Monitoring will retry.") }
                readOffset += UInt64(chunk.count); next.bytesRead += UInt64(chunk.count)
                // Include FileHandle's autoreleased read buffers as well as parser temporaries.
                do { try next.append(chunk) }
                catch InspectorError.recordTooLarge {
                    throw InspectorError.recordTooLarge(indexedEvidenceAvailable: lastSnapshot != nil)
                }
            }
        }
        let (afterSize, afterInode, afterModified) = try LogReader.metadata(url)
        guard afterInode == newInode, afterSize >= newSize, afterSize != newSize || afterModified == newModified else {
            throw InspectorError.invalid("The source changed while indexing. Monitoring will retry.")
        }
        next.size = newSize; next.modified = newModified
        next.head = try read(0, Int(min(4096, newSize)))
        next.tail = try read(newSize - min(4096, newSize), Int(min(4096, newSize)))
        var preview = next.builder
        var indexedRecords = next.records
        if var c = next.current {
            c.source.digest = SHA256.hash(data: next.recordBytes).description
            try preview.consume(c)
            indexedRecords.append(IndexedLogRecord(c))
        }
        if !next.buffer.isEmpty {
            // Do not withdraw the preceding complete evidence while the next line
            // is arriving. The fragment has its own source reference until framed.
            let ref = SourceRef(offset: next.offset, length: next.buffer.count, line: next.line, endLine: next.line,
                                digest: SHA256.hash(data: next.buffer).description)
            let partial = LogRecord(source: ref, timestamp: "", logger: "unknown", level: "WARNING",
                                    body: "Incomplete final record at current boundary")
            try preview.consume(partial)
            indexedRecords.append(IndexedLogRecord(partial))
        }
        preview.finish()
        let snapshot = LogSnapshot(url: url, size: newSize, inode: newInode, modified: newModified,
                                   turns: preview.turns, recordCount: next.count + (next.current == nil ? 0 : 1) + (next.buffer.isEmpty ? 0 : 1), warnings: preview.warnings,
                                   generation: next.generation, hasPartialRecord: !next.buffer.isEmpty, records: indexedRecords)
        next.lastSnapshot = snapshot
        self = next
        return IndexUpdate(snapshot: snapshot, reset: reason != nil, recovery: reason)
    }

    private mutating func append(_ data: Data) throws {
        buffer.append(data)
        var used = buffer.startIndex
        while let end = buffer[used...].firstIndex(of: 10) {
            try accept(Data(buffer[used...end]))
            used = end + 1
        }
        if used > buffer.startIndex { buffer = Data(buffer[used...]) }
        guard buffer.count + recordBytes.count <= LogReader.maximumRecord else {
            throw InspectorError.recordTooLarge(indexedEvidenceAvailable: false)
        }
    }

    private mutating func accept(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        if let m = LogReader.header.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            if var c = current {
                c.source.digest = SHA256.hash(data: recordBytes).description
                try builder.consume(c); count += 1
                records.append(IndexedLogRecord(c))
            }
            recordBytes = Data()
            let parts = (1...5).map { String(text[Range(m.range(at: $0), in: text)!]) }
            current = LogRecord(source: SourceRef(offset: offset, length: data.count, line: line, endLine: line), timestamp: parts[0], logger: parts[1], level: parts[2], body: parts[4], context: parts[3])
        } else if var c = current {
            c.body += "\n" + text; c.source.length += data.count; c.source.endLine = line; current = c
        } else if !text.isEmpty {
            current = LogRecord(source: SourceRef(offset: offset, length: data.count, line: line, endLine: line), timestamp: "", logger: "unknown", level: "WARNING", body: "Unframed source content\n" + text)
        }
        recordBytes.append(data)
        guard recordBytes.count <= LogReader.maximumRecord else { throw InspectorError.recordTooLarge(indexedEvidenceAvailable: false) }
        offset += UInt64(data.count); line += 1
    }
}

/// Serializes updates without doing file I/O on the main actor.
public actor LogSession {
    private var index: LogIndex
    public init(url: URL) { index = LogIndex(url: url) }
    public func refresh() throws -> IndexUpdate? { try index.refresh() }
}
