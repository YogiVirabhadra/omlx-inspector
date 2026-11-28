import Foundation

/// One framed log record: a header line plus any continuation lines, before interpretation.
struct LogRecord: Sendable {
    var source: SourceRef
    var timestamp: String
    var logger: String
    var level: String
    var body: String
    var context: String = "-"
}

/// The result of a refresh that found new or changed source content.
public struct IndexUpdate: Sendable {
    public var snapshot: LogSnapshot
    /// `true` when a new source generation was indexed from scratch.
    public var reset: Bool
    /// A user-facing explanation of why the generation changed.
    public var recovery: String?
}

/// A streaming, in-memory offset index. Source bodies are not retained in the index.
/// The trailing record is interpreted provisionally and replayed when its boundary grows.
public struct LogIndex: Sendable {
    /// The largest single record, in bytes, that will be indexed.
    static let maximumRecordBytes = 64 * 1024 * 1024

    public let url: URL
    /// Total bytes read for the current generation. Lets tests confirm refreshes are incremental.
    public private(set) var bytesRead: UInt64 = 0
    private var size: UInt64 = 0
    private var inode: UInt64 = 0
    private var modified: Date = .distantPast
    private var generation = UUID().uuidString
    private var head = Data()
    private var tail = Data()
    private var builder = EvidenceBuilder()
    private var buffer = Data()
    private var recordBytes = Data()
    private var current: LogRecord?
    private var records = RecordList()
    private var loggers: Set<String> = []
    private var offset: UInt64 = 0
    private var line = 1
    private var count = 0
    /// Whether a snapshot has been produced, so later refreshes compare against this state.
    private var hasIndexed = false

    public init(url: URL) { self.url = url }

    /// Reads any new bytes and returns an updated snapshot, or `nil` if the file is unchanged.
    ///
    /// Appended data is read incrementally. Replacement, truncation, or rewriting starts a new
    /// generation. The index is only updated after a complete, successful read, so cancellation
    /// or an error leaves the previous state intact.
    public mutating func refresh() throws -> IndexUpdate? {
        let latest = try FileIdentity(of: url)
        if hasIndexed, latest.size == size, latest.inode == inode, latest.modified == modified { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func read(_ at: UInt64, _ length: Int) throws -> Data {
            try file.seek(toOffset: at)
            return try file.read(upToCount: length) ?? Data()
        }
        var reason: String?
        if hasIndexed {
            if latest.inode != inode {
                reason = "Log replaced or rotated. A new source generation was indexed."
            } else if latest.size < size {
                reason = "Log truncated. A new source generation was indexed."
            } else if try latest.size == size || read(0, head.count) != head
                || read(size - UInt64(tail.count), tail.count) != tail
            {
                reason = "Log rewritten. A new source generation was indexed."
            }
        }
        // Commit only after a successful complete read; cancellation/errors retain the old index.
        var next = reason == nil ? self : LogIndex(url: url)
        next.inode = latest.inode
        try file.seek(toOffset: next.size)
        var readOffset = next.size
        while readOffset < latest.size {
            try autoreleasepool {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: Int(min(65536, latest.size - readOffset))) ?? Data()
                guard !chunk.isEmpty else {
                    throw InspectorError.sourceChangedWhileIndexing
                }
                readOffset += UInt64(chunk.count)
                next.bytesRead += UInt64(chunk.count)
                // Include FileHandle's autoreleased read buffers as well as parser temporaries.
                do { try next.append(chunk) } catch InspectorError.recordTooLarge {
                    throw InspectorError.recordTooLarge(indexedEvidenceAvailable: hasIndexed)
                }
            }
        }
        let after = try FileIdentity(of: url)
        guard after.inode == latest.inode, after.size >= latest.size,
            after.size != latest.size || after.modified == latest.modified
        else {
            throw InspectorError.sourceChangedWhileIndexing
        }
        next.size = latest.size
        next.modified = latest.modified
        next.head = try read(0, Int(min(4096, latest.size)))
        next.tail = try read(latest.size - min(4096, latest.size), Int(min(4096, latest.size)))
        // The open record and any partial line are interpreted provisionally, in copies, so the
        // index itself only ever holds complete records. Copies of `RecordList` share storage.
        var snapshotBuilder = next.builder
        var indexedRecords = next.records
        var indexedLoggers = next.loggers
        if var openRecord = next.current {
            openRecord.source.digest = SHA256Hex.digest(of: next.recordBytes)
            try snapshotBuilder.consume(openRecord)
            indexedRecords.append(IndexedLogRecord(openRecord))
            indexedLoggers.insert(openRecord.logger)
        }
        if !next.buffer.isEmpty {
            // Do not withdraw the preceding complete evidence while the next line
            // is arriving. The fragment has its own source reference until framed.
            let ref = SourceRef(
                offset: next.offset, length: next.buffer.count, line: next.line, endLine: next.line,
                digest: SHA256Hex.digest(of: next.buffer))
            let partial = LogRecord(
                source: ref, timestamp: "", logger: LogGrammar.unknownLogger, level: "WARNING",
                body: LogGrammar.incompleteRecordPrefix + " at current boundary")
            try snapshotBuilder.consume(partial)
            indexedRecords.append(IndexedLogRecord(partial))
            indexedLoggers.insert(partial.logger)
        }
        snapshotBuilder.finish()
        let snapshot = LogSnapshot(
            url: url, size: latest.size, inode: latest.inode, modified: latest.modified,
            turns: snapshotBuilder.turns,
            recordCount: next.count + (next.current == nil ? 0 : 1) + (next.buffer.isEmpty ? 0 : 1),
            warnings: snapshotBuilder.warnings,
            generation: next.generation, hasPartialRecord: !next.buffer.isEmpty, records: indexedRecords,
            loggers: indexedLoggers.sorted())
        next.hasIndexed = true
        self = next
        return IndexUpdate(snapshot: snapshot, reset: reason != nil, recovery: reason)
    }

    /// Buffers raw bytes and hands each complete line to ``accept(_:)``.
    private mutating func append(_ data: Data) throws {
        buffer.append(data)
        var used = buffer.startIndex
        while let end = buffer[used...].firstIndex(of: 10) {
            try accept(Data(buffer[used...end]))
            used = end + 1
        }
        if used > buffer.startIndex { buffer = Data(buffer[used...]) }
        guard buffer.count + recordBytes.count <= Self.maximumRecordBytes else {
            throw InspectorError.recordTooLarge(indexedEvidenceAvailable: false)
        }
    }

    /// Consumes one complete line: a header starts a new record (closing the previous one),
    /// anything else continues the open record.
    private mutating func accept(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        if let headerMatch = LogGrammar.headerExpression.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text))
        {
            if var openRecord = current {
                openRecord.source.digest = SHA256Hex.digest(of: recordBytes)
                try builder.consume(openRecord)
                count += 1
                records.append(IndexedLogRecord(openRecord))
                loggers.insert(openRecord.logger)
            }
            recordBytes = Data()
            let parts = (1...5).map { String(text[Range(headerMatch.range(at: $0), in: text)!]) }
            current = LogRecord(
                source: SourceRef(offset: offset, length: data.count, line: line, endLine: line), timestamp: parts[0],
                logger: parts[1], level: parts[2], body: parts[4], context: parts[3])
        } else if current != nil {
            // Mutate in place. Copying the record out and back would duplicate its
            // growing body on every continuation line (quadratic for long outputs).
            current?.body += "\n" + text
            current?.source.length += data.count
            current?.source.endLine = line
        } else if !text.isEmpty {
            current = LogRecord(
                source: SourceRef(offset: offset, length: data.count, line: line, endLine: line), timestamp: "",
                logger: LogGrammar.unknownLogger, level: "WARNING", body: "Unframed source content\n" + text)
        } else {
            // A blank line before the first record belongs to no record. Keeping it out of
            // `recordBytes` keeps the digest aligned with the record's source range.
            offset += UInt64(data.count)
            line += 1
            return
        }
        recordBytes.append(data)
        guard recordBytes.count <= Self.maximumRecordBytes else {
            throw InspectorError.recordTooLarge(indexedEvidenceAvailable: false)
        }
        offset += UInt64(data.count)
        line += 1
    }
}

/// Serializes updates without doing file I/O on the main actor.
public actor LogSession {
    private var index: LogIndex
    public init(url: URL) { index = LogIndex(url: url) }
    public func refresh() throws -> IndexUpdate? { try index.refresh() }
}
