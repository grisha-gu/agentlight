import Foundation

/// Персистентность привязок: `~/.agentlight/state.json`, атомарная запись.
public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL = Paths.state) {
        self.url = url
    }

    public func load() -> SlotAllocator? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SlotAllocator.self, from: data)
    }

    public func save(_ allocator: SlotAllocator) throws {
        try AtomicFile.write(Self.encoder.encode(allocator), to: url)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
