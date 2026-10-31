import Foundation

/// Хвост transcript-файла сессии: ищет отметку прерывания.
///
/// Esc на вопросе или запросе разрешения, как и Esc посреди хода, не шлёт ни одного хука:
/// Claude Code только дописывает в transcript строку пользователя с текстом
/// `[Request interrupted by user]` / `[Request interrupted by user for tool use]`.
/// Без неё светофор так и горел бы красным (или жёлтым) до следующего промпта.
public struct TranscriptTail: Sendable {
    static let marker = "[Request interrupted by user"
    private static let markerBytes = Data(marker.utf8)
    /// строка без перевода строки на конце — дописывается следующим куском
    private var pending = Data()

    public init() {}

    /// Скормить дописанные байты. true — среди целых строк есть отметка прерывания.
    public mutating func feed(_ data: Data) -> Bool {
        pending.append(data)
        var found = false
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            if !found, line.range(of: Self.markerBytes) != nil, Self.isInterrupt(line) { found = true }
            pending = Data(pending[pending.index(after: nl)...])
        }
        // огромный результат инструмента без конца строки — не копим бесконечно
        if pending.count > 16 << 20 { pending = Data() }
        return found
    }

    /// Строка пользователя, где отметка — сам текст сообщения, а не кусок вывода инструмента.
    static func isInterrupt(_ line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "user",
              let message = obj["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return text.hasPrefix(marker) }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix(marker) == true }
    }
}
