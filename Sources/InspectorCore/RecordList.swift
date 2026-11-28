import Foundation

/// An append-only list of indexed records that is cheap to copy.
///
/// A snapshot handed to the UI and the index that keeps growing behind it share the same
/// records. With a plain array, the first append after a snapshot was taken copied every
/// record, once per live refresh. Here records live in fixed-size chunks: a copy shares all of
/// them, and appending to a copy duplicates only the outer chunk list and the last chunk.
public struct RecordList: RandomAccessCollection, ExpressibleByArrayLiteral, Equatable, Sendable {
    /// Records per chunk. Large enough to keep the chunk list short, small enough that copying
    /// one chunk is negligible.
    static let chunkSize = 4096

    private var chunks: [[IndexedLogRecord]] = []
    public private(set) var count = 0

    /// An empty list.
    public init() {}

    /// A list holding `records`, in order.
    public init<Records: Sequence>(_ records: Records) where Records.Element == IndexedLogRecord {
        for record in records { append(record) }
    }

    public init(arrayLiteral records: IndexedLogRecord...) {
        self.init(records)
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> IndexedLogRecord {
        precondition(indices.contains(position), "RecordList index out of range")
        return chunks[position / Self.chunkSize][position % Self.chunkSize]
    }

    mutating func append(_ record: IndexedLogRecord) {
        if chunks.last.map({ $0.count == Self.chunkSize }) ?? true {
            var chunk: [IndexedLogRecord] = []
            chunk.reserveCapacity(Self.chunkSize)
            chunks.append(chunk)
        }
        chunks[chunks.count - 1].append(record)
        count += 1
    }

    /// The position of the record with the given ``IndexedLogRecord/id``, found by binary search
    /// on the source offset the ID encodes. `nil` if no such record is in the list.
    public func index(ofRecordID id: String) -> Int? {
        guard let offset = Identifiers.offset(ofRecord: id) else { return nil }
        let index = firstIndex(atOrAfter: offset)
        return index < count && self[index].source.offset == offset ? index : nil
    }

    /// The record with the given ``IndexedLogRecord/id``, or `nil` if it is not in the list.
    public func record(withID id: String) -> IndexedLogRecord? {
        index(ofRecordID: id).map { self[$0] }
    }

    /// The index of the first record at or after `offset`, assuming records are in source order
    /// (as they are in every snapshot and every filtered list). Returns `endIndex` if every record
    /// starts before it.
    func firstIndex(atOrAfter offset: UInt64) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].source.offset < offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    public static func == (lhs: RecordList, rhs: RecordList) -> Bool {
        lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }
}
