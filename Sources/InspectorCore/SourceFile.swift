import Foundation

/// The properties that identify one version of a log file on disk.
struct FileIdentity: Equatable, Sendable {
    var size: UInt64
    /// File-system inode; changes when the file is replaced or rotated.
    var inode: UInt64
    var modified: Date

    /// Reads the identity of the regular file at `url`.
    init(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw InspectorError.notRegularFile
        }
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date ?? .distantPast
    }
}

extension LogSnapshot {
    /// Reads a record's bytes from disk, refusing them if the file was replaced or the bytes no
    /// longer match the digest captured at indexing time.
    func verifiedText(of source: SourceRef) throws -> String {
        let current = try FileIdentity(of: url)
        guard current.inode == inode, current.size >= size, current.size != size || current.modified == modified
        else {
            throw InspectorError.sourceReplaced
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: source.offset)
        let data = try handle.read(upToCount: source.length) ?? Data()
        guard data.count == source.length else {
            throw InspectorError.sourceUnavailable
        }
        guard SHA256Hex.digest(of: data) == source.digest else {
            throw InspectorError.recordChanged
        }
        return String(decoding: data, as: UTF8.self)
    }
}
