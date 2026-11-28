import XCTest
@testable import InspectorCore

final class StructuredTests: XCTestCase {
    func flatten(_ value: StructuredValue) -> [StructuredValue] { [value] + value.children.flatMap(flatten) }
    func testEveryValueSurvivesTreeRoundTrip() throws {
        let long = String(repeating: "System prompt\n\t\"unicode 🧘\" ", count: 10000)
        let object: [String: Any] = [
            "messages": [
                ["role": "system", "content": long],
                [
                    "role": "assistant", "content": NSNull(),
                    "tool_calls": [["function": ["name": "terminal", "arguments": "{\"command\":\"date\"}"]]]
                ], ["role": "tool", "content": "Friday"]
            ],
            "tools": [
                [
                    "function": [
                        "name": "terminal",
                        "parameters": ["type": "object", "properties": ["command": ["type": "string"]]]
                    ]
                ]
            ],
            "temperature": 0.7, "stream": true, "zero": 0, "one": 1, "null": NSNull(), "emptyArray": [],
            "emptyObject": [:], "escaped/~key": ["x/y": "value"], "unknown": ["custom": [false, 3.25, "hi"]]
        ]
        let tree = try StructuredValue.parse(JSONText.prettyPrinted(object), retainedMessages: 1)
        let nodes = flatten(tree)
        XCTAssertEqual(nodes.count, Set(nodes.map(\.id)).count)
        XCTAssertEqual(tree.children.first?.key, "messages")
        let messages = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(messages.children.map(\.label), ["[0] system", "[1] assistant", "[2] tool"])
        XCTAssertEqual(messages.children.map(\.isNewMessage), [false, true, true])
        let prompt = try XCTUnwrap(nodes.first { $0.id == "/messages/0/content" })
        XCTAssertEqual(prompt.completeText, long)
        XCTAssertLessThan(prompt.preview.count, 210)
        XCTAssertTrue(prompt.children.isEmpty)
        XCTAssertEqual(nodes.first { $0.id == "/escaped~1~0key/x~1y" }?.completeText, "value")
        XCTAssertEqual(nodes.first { $0.id == "/stream" }?.kind, .boolean)
        XCTAssertEqual(nodes.first { $0.id == "/one" }?.kind, .number)
        let reconstructed = try JSONSerialization.jsonObject(with: Data(tree.json().utf8))
        XCTAssertEqual(JSONText.fingerprint(reconstructed), JSONText.fingerprint(object))
        for node in nodes {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(node.json().utf8), options: [.fragmentsAllowed]))
        }
    }
    func testSavedPathsResolveAgainstFreshTreeWithoutIndexOrEscapingCollisions() throws {
        let json =
            #"{"messages":[{"role":"system","content":"Instructions"},{"role":"tool","content":"Result"}],"a/b":{"~key":"Value"},"a":{"b":"Different"}}"#
        let original = try StructuredValue.parse(json)
        let rebuilt = try StructuredValue.parse(json)
        for node in flatten(original) {
            let restored = try XCTUnwrap(rebuilt.node(at: node.id))
            XCTAssertEqual(restored.completeText, node.completeText)
            XCTAssertFalse(restored === node)
        }
        XCTAssertEqual(rebuilt.node(at: "/a~1b/~0key")?.completeText, "Value")
        XCTAssertNil(rebuilt.node(at: "/messages/10/content"))
        XCTAssertNil(rebuilt.node(at: "/messages/1/missing"))
    }
    func testUnknownComparisonDoesNotMarkMessagesNew() throws {
        let tree = try StructuredValue.parse(#"{"messages":[{"role":"user","content":"Hi"}],"tools":[]}"#)
        XCTAssertFalse(flatten(tree).contains(where: \.isNewMessage))
        let summary = DetailText.request(
            RequestPayload(raw: ["messages": [["role": "user", "content": "Hi"]]]), continuation: nil)
        XCTAssertTrue(summary.contains("comparison unavailable"))
        XCTAssertFalse(summary.contains("New user"))
    }
    func testSummaryUsesStructuredCallsAndReportedPayload() {
        let request: [String: Any] = [
            "model": "fixture-model",
            "messages": [
                ["role": "system", "content": String(repeating: "Secret long prompt ", count: 1000)],
                ["role": "user", "content": "date?"],
                [
                    "role": "assistant", "content": NSNull(),
                    "tool_calls": [["function": ["name": "terminal", "arguments": "{\"command\":\"date\"}"]]]
                ],
                [
                    "role": "tool",
                    "content":
                        "<untrusted_tool_result source=\"x\">\nSafety text\n\n{\"output\":\"Friday\",\"exit_code\":0}\n</untrusted_tool_result>"
                ]
            ], "tools": [[:], [:]], "custom": "preserved"
        ]
        let text = DetailText.request(
            RequestPayload(raw: request),
            continuation: RequestContinuation(
                reason: "Continuing after terminal result", totalMessages: 4, retainedMessages: 2))
        XCTAssertTrue(text.contains("Messages: 4 total, 2 newly introduced, 2 retained"))
        XCTAssertTrue(text.contains("Available tools: 2"))
        XCTAssertTrue(text.contains("terminal({\"command\":\"date\"})"))
        XCTAssertTrue(text.contains("Friday"))
        XCTAssertFalse(text.contains("Secret long prompt"))
        XCTAssertFalse(text.contains("Safety text"))
    }
    func testNonObjectRootsAndEmptyValues() throws {
        for text in ["[]", "{}", "null", "true", "123", #""""#, #"["a",{"b":[]}]"#] {
            let tree = try StructuredValue.parse(text)
            let a = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let b = try JSONSerialization.jsonObject(with: Data(tree.json().utf8), options: [.fragmentsAllowed])
            XCTAssertEqual(JSONText.fingerprint(a), JSONText.fingerprint(b))
        }
    }
}
