import Foundation

/// Tail of a session's transcript file: looks for the interruption marker.
///
/// Esc on a question or permission prompt, like Esc mid-turn, sends no hook at all:
/// Claude Code only appends a user line to the transcript with the text
/// `[Request interrupted by user]` / `[Request interrupted by user for tool use]`.
/// Without it the traffic light would stay red (or yellow) until the next prompt.
public struct TranscriptTail: Sendable {
    static let marker = "[Request interrupted by user"
    private static let markerBytes = Data(marker.utf8)
    /// a line without a trailing newline — completed by the next chunk
    private var pending = Data()

    public init() {}

    /// Feed appended bytes. true — one of the complete lines has the interruption marker.
    public mutating func feed(_ data: Data) -> Bool {
        pending.append(data)
        var found = false
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            if !found, line.range(of: Self.markerBytes) != nil, Self.isInterrupt(line) { found = true }
            pending = Data(pending[pending.index(after: nl)...])
        }
        // a huge tool result without a line break — don't accumulate forever
        if pending.count > 16 << 20 { pending = Data() }
        return found
    }

    /// A user line where the marker is the message text itself, not part of tool output.
    static func isInterrupt(_ line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "user",
              let message = obj["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return text.hasPrefix(marker) }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix(marker) == true }
    }
}
