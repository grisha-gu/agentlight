import Foundation

/// Простой лог в stderr (под launchd он уходит в ~/.agentlight/agentlightd.log)
/// или прямо в файл, когда терминал занят рендером --fake-device.
public enum Log {
    nonisolated(unsafe) public static var fileHandle: FileHandle?
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func toFile(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    public static func info(_ msg: @autoclosure () -> String) { write("I", msg()) }
    public static func warn(_ msg: @autoclosure () -> String) { write("W", msg()) }
    public static func error(_ msg: @autoclosure () -> String) { write("E", msg()) }

    private static func write(_ level: String, _ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(level) \(msg)\n"
        if let fh = fileHandle {
            fh.write(Data(line.utf8))
        } else {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
