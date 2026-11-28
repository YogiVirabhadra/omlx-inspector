import CryptoKit
import XCTest
@testable import InspectorCore

final class RequestPayloadTests: XCTestCase {
    private func originalFingerprint(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func testHeterogeneousContentAndUnknownFieldsKeepOriginalFingerprints() throws {
        let shapes: [Any] = [
            "text", NSNull(), [["type": "image_url", "image_url": ["url": "data:fixture"]]],
            ["custom": [1, true, NSNull()]], 42
        ]
        for content in shapes {
            let message: [String: Any] = ["role": "user", "content": content, "future": ["kept": true]]
            let raw: [String: Any] = [
                "model": "fixture", "messages": [message], "tools": [NSNull(), ["unknown": true]],
                "future": ["nested": "kept"]
            ]
            let payload = RequestPayload(raw: raw)
            let projected = RequestPayload.Message(raw: try XCTUnwrap(payload.messages?.first))
            XCTAssertEqual(projected.content, JSONText.displayText(content))
            XCTAssertEqual(projected.role, "user")
            XCTAssertEqual(payload.toolCount, 2)
            XCTAssertEqual(JSONText.fingerprint(payload.raw), try originalFingerprint(raw))
            XCTAssertEqual(JSONText.fingerprint(projected.raw), try originalFingerprint(message))
            XCTAssertNotNil(payload.raw["future"])
            XCTAssertNotNil(projected.raw["future"])
        }
    }
    func testMalformedFieldsPreserveLegacyFallbacks() {
        let payload = RequestPayload(raw: [
            "model": 42, "messages": ["not an object"], "tools": "invalid",
            "response_format": ["json_schema": ["name": 3]]
        ])
        XCTAssertEqual(payload.model, "Unspecified model")
        XCTAssertNil(payload.messages)
        XCTAssertEqual(payload.toolCount, 0)
        XCTAssertFalse(payload.isSessionTitle)
        let message = RequestPayload.Message(raw: ["role": 42, "tool_call_id": 123, "tool_calls": ["invalid"]])
        XCTAssertEqual(message.role, "unknown")
        XCTAssertEqual(message.content, "")
        XCTAssertNil(message.toolCallID)
        XCTAssertNil(message.toolCalls)
        let call = RequestPayload.ToolCall(raw: ["id": 42, "function": "invalid"])
        XCTAssertNil(call.id)
        XCTAssertEqual(call.name, "Unnamed tool")
        XCTAssertEqual(call.arguments, "")
        XCTAssertTrue(
            RequestPayload(raw: ["response_format": ["json_schema": ["name": "session_title"]]]).isSessionTitle)
    }
    func testTypedCallsPreserveStructuredArgumentsAndRawJSON() throws {
        let raw: [String: Any] = [
            "role": "assistant",
            "tool_calls": [["id": "a", "function": ["name": "tool", "arguments": ["flag": true]], "extra": 1]]
        ]
        let call = try XCTUnwrap(RequestPayload.Message(raw: raw).toolCalls?.first)
        XCTAssertEqual(call.id, "a")
        XCTAssertEqual(call.name, "tool")
        XCTAssertEqual(call.arguments, JSONText.prettyPrinted(["flag": true]))
        XCTAssertNotNil(call.raw["extra"])
        let reordered: [String: Any] = ["tool_calls": raw["tool_calls"]!, "role": "assistant"]
        XCTAssertEqual(JSONText.fingerprint(raw), JSONText.fingerprint(reordered))
    }
}
