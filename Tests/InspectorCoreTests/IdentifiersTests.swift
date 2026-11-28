import XCTest

@testable import InspectorCore

/// Identifiers are persisted to restore selections, so their format is part of the contract.
final class IdentifiersTests: XCTestCase {
    func testFormatsAreStable() {
        XCTAssertEqual(Identifiers.diagnosticsTurn, "diagnostics")
        XCTAssertEqual(Identifiers.userTurn(requestAt: 42, messageIndex: 3), "t42-3")
        XCTAssertEqual(Identifiers.turnWithoutUser(requestAt: 42), "t42")
        XCTAssertEqual(Identifiers.unlinkedOutputTurn(outputAt: 42), "unlinked42")
        XCTAssertEqual(Identifiers.requestEvent(at: 42), "r42")
        XCTAssertEqual(Identifiers.messageEvent(requestAt: 42, messageIndex: 3), "m42-3")
        XCTAssertEqual(Identifiers.callEvent(requestAt: 42, messageIndex: 3, callIndex: 1), "m42-3c1")
        XCTAssertEqual(Identifiers.outputEvent(at: 42), "o42")
        XCTAssertEqual(Identifiers.diagnosticEvent(at: 42), "d42")
        XCTAssertEqual(Identifiers.diagnosticEvent(at: 42, discriminator: "abc"), "d42-abc")
        XCTAssertEqual(Identifiers.record(at: 42), "l42")
    }

    func testRecordOffsetsRoundTrip() {
        for offset: UInt64 in [0, 1, 4096, .max] {
            XCTAssertEqual(Identifiers.offset(ofRecord: Identifiers.record(at: offset)), offset)
        }
        for invalid in ["", "l", "x10", "l-1", "l1x", "r10"] {
            XCTAssertNil(Identifiers.offset(ofRecord: invalid), invalid)
        }
    }
}
