import Foundation

/// The identifier scheme for turns, events, and records.
///
/// Identifiers are derived from source offsets, so they are stable within a source generation
/// and can be persisted to restore a selection. Each kind has its own prefix, so identifiers of
/// different kinds never collide. Build identifiers only through these functions.
enum Identifiers {
    // MARK: Turns

    /// The single turn that collects unattributed diagnostics.
    static let diagnosticsTurn = "diagnostics"

    /// A turn opened by the user message at `index` in the request at `offset`.
    static func userTurn(requestAt offset: UInt64, messageIndex index: Int) -> String { "t\(offset)-\(index)" }

    /// A turn for a request whose history contains no user message.
    static func turnWithoutUser(requestAt offset: UInt64) -> String { "t\(offset)" }

    /// A turn for model output that could not be associated with any request.
    static func unlinkedOutputTurn(outputAt offset: UInt64) -> String { "unlinked\(offset)" }

    // MARK: Events

    /// The incoming request at `offset`.
    static func requestEvent(at offset: UInt64) -> String { "r\(offset)" }

    /// The message at `index` in the history of the request at `offset`.
    static func messageEvent(requestAt offset: UInt64, messageIndex index: Int) -> String { "m\(offset)-\(index)" }

    /// A structured tool call within a message.
    static func callEvent(requestAt offset: UInt64, messageIndex index: Int, callIndex: Int) -> String {
        messageEvent(requestAt: offset, messageIndex: index) + "c\(callIndex)"
    }

    /// The scheduler's generated-output record at `offset`.
    static func outputEvent(at offset: UInt64) -> String { "o\(offset)" }

    /// A diagnostic for the record at `offset`. `discriminator` separates several diagnostics
    /// derived from one record.
    static func diagnosticEvent(at offset: UInt64, discriminator: String? = nil) -> String {
        "d\(offset)" + (discriminator.map { "-" + $0 } ?? "")
    }

    // MARK: Records

    /// The framed record at `offset`.
    static func record(at offset: UInt64) -> String { "l\(offset)" }

    /// The source offset encoded in a record identifier, or `nil` if `id` is not one.
    static func offset(ofRecord id: String) -> UInt64? {
        guard id.hasPrefix("l") else { return nil }
        return UInt64(id.dropFirst())
    }
}
