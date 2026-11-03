import AgentLightKit
import Foundation

/// Watches the transcript files of live sessions and reports Esc interruptions (see `TranscriptTail`).
/// Reads only what was appended after watching started. Everything on the main queue.
final class TranscriptWatcher {
    var onInterrupt: ((String) -> Void)?

    private final class Watch {
        let path: String
        let handle: FileHandle
        let source: DispatchSourceFileSystemObject
        var tail = TranscriptTail()
        var offset: UInt64

        init(path: String, handle: FileHandle, source: DispatchSourceFileSystemObject, offset: UInt64) {
            self.path = path
            self.handle = handle
            self.source = source
            self.offset = offset
        }
    }

    private var watches: [String: Watch] = [:]

    /// Bring the set of watches in line with `sessions` (session_id → path). A file that doesn't exist yet
    /// is picked up on the next call.
    func sync(_ sessions: [String: String]) {
        for (id, w) in watches where sessions[id] != w.path {
            w.source.cancel()
            watches[id] = nil
        }
        for (id, path) in sessions where watches[id] == nil {
            watch(id, path)
        }
    }

    private func watch(_ id: String, _ path: String) {
        let fd = open(path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let offset = (try? handle.seekToEnd()) ?? 0
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        let w = Watch(path: path, handle: handle, source: source, offset: offset)
        source.setEventHandler { [weak self, weak w] in
            guard let self, let w else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // the file was replaced — reopen it on the next sync
                source.cancel()
                if self.watches[id] === w { self.watches[id] = nil }
                return
            }
            self.read(id, w)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watches[id] = w
    }

    private func read(_ id: String, _ w: Watch) {
        guard let end = try? w.handle.seekToEnd() else { return }
        if end < w.offset { w.offset = end }  // the file was truncated
        guard end > w.offset else { return }
        try? w.handle.seek(toOffset: w.offset)
        guard let data = try? w.handle.read(upToCount: Int(end - w.offset)) else { return }
        w.offset += UInt64(data.count)
        if w.tail.feed(data) { onInterrupt?(id) }
    }
}
