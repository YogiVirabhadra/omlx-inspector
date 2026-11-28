import Foundation

/// A selective typed view of the already-decoded JSON, not a second serialization
/// model. Unknown fields and heterogeneous message content stay in `raw`.
/// Fingerprints must always use the original JSON values, never this projection.
struct RequestPayload {
    let raw: [String: Any]

    init(raw: [String: Any]) {
        self.raw = raw
    }

    /// Decodes the JSON body that follows the request separator in an incoming-request record.
    init(decoding record: LogRecord) throws {
        guard let range = record.body.range(of: LogGrammar.requestBodySeparator),
            let object = try JSONSerialization.jsonObject(with: Data(record.body[range.upperBound...].utf8))
                as? [String: Any]
        else { throw InspectorError.unsupportedRequestBody }
        raw = object
    }

    var model: String { raw["model"] as? String ?? "Unspecified model" }
    var messages: [[String: Any]]? { raw["messages"] as? [[String: Any]] }
    var toolCount: Int { (raw["tools"] as? [Any])?.count ?? 0 }
    var isSessionTitle: Bool {
        guard let format = raw["response_format"] as? [String: Any],
            let schema = format["json_schema"] as? [String: Any]
        else { return false }
        return schema["name"] as? String == "session_title"
    }

    struct Message {
        let raw: [String: Any]
        var role: String { raw["role"] as? String ?? "unknown" }
        var content: String { JSONText.displayText(raw["content"]) }
        var toolCallID: String? { raw["tool_call_id"] as? String }
        var toolCalls: [ToolCall]? { (raw["tool_calls"] as? [[String: Any]])?.map { ToolCall(raw: $0) } }
    }
    struct ToolCall {
        let raw: [String: Any]
        var id: String? { raw["id"] as? String }
        private var function: [String: Any] { raw["function"] as? [String: Any] ?? [:] }
        /// The function name exactly as reported, if it is a string.
        var reportedName: String? { function["name"] as? String }
        var name: String { reportedName ?? "Unnamed tool" }
        var arguments: String { JSONText.displayText(function["arguments"]) }
    }
}
