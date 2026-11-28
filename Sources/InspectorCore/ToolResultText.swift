import Foundation

/// Interpretation of agent-reported tool results.
///
/// Everything here describes what the agent reported. A reported success or failure is not
/// independent evidence of what the tool actually did.
enum ToolResultText {
    /// The payload inside an agent's `<untrusted_tool_result>` safety wrapper, or `content` unchanged.
    static func payload(_ content: String) -> String {
        if content.hasPrefix(LogGrammar.resultWrapperOpen),
            let end = content.range(of: LogGrammar.resultWrapperClose, options: .backwards),
            let start = content.range(of: LogGrammar.resultWrapperSeparator), start.upperBound < end.lowerBound
        {
            return String(content[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content
    }

    /// A tool result reduced to one line, and whether the agent reported it as a failure.
    struct Summary: Equatable {
        var text: String
        var reportsFailure: Bool
    }

    /// A one-line summary of a tool result. Reported failures are labeled "Reported error".
    static func summary(_ content: String) -> Summary {
        let payload = payload(content)
        if let result = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
            let failure =
                (result["success"] as? Bool == false) || ((result["exit_code"] as? Int ?? 0) != 0)
                || !(JSONText.displayText(result["error"]).isEmpty)
            if failure {
                let explanation =
                    [
                        JSONText.displayText(result["error"]),
                        JSONText.displayText(result["stderr"]).split(separator: "\n").last.map(String.init) ?? "",
                        JSONText.displayText(result["output"])
                    ].first { !$0.isEmpty } ?? "Nonzero exit code or unsuccessful result"
                return Summary(text: "Reported error · " + TextPreview.singleLine(explanation), reportsFailure: true)
            }
            let output = JSONText.displayText(result["output"])
            if !output.isEmpty { return Summary(text: TextPreview.singleLine(output), reportsFailure: false) }
        }
        return Summary(text: TextPreview.singleLine(payload), reportsFailure: false)
    }
}
