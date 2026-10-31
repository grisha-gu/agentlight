import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType = "application/json"

    public init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static let noContent = HTTPResponse(status: 204)
    public static let notFound = HTTPResponse(status: 404)

    public static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        HTTPResponse(status: 200, body: (try? StateStore.encoder.encode(value)) ?? Data())
    }
}

/// Минимальный HTTP/1.1 только на 127.0.0.1 (docs/05-host-macos.md §5.3):
/// keep-alive обязателен, `POST /hook` отвечает 204 до какой-либо обработки, 5xx не бывает.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let port: UInt16
    private let queue = DispatchQueue(label: "agentlight.http")
    private var listener: NWListener?
    /// `POST /hook`: тело отдаётся сюда уже после ответа 204
    public var onHook: ((Data) -> Void)?
    /// всё остальное (`/status`, `/control`)
    public var handler: Handler?
    public var onFailure: ((Error) -> Void)?

    public init(port: UInt16) {
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { self?.onFailure?(err) }
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            self.drain(c, &buf)
            if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    /// Разобрать все целые запросы из буфера (несколько подряд в одном соединении).
    private func drain(_ c: NWConnection, _ buf: inout Data) {
        while let req = Self.parse(&buf) {
            if req.method == "POST" && req.path == "/hook" {
                respond(c, .noContent)
                onHook?(req.body)
            } else if let handler {
                handler(req) { [weak self] resp in
                    self?.queue.async { self?.respond(c, resp) }
                }
            } else {
                respond(c, .notFound)
            }
        }
    }

    /// nil — запрос ещё не пришёл целиком.
    static func parse(_ buf: inout Data) -> HTTPRequest? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        var length = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= length else { return nil }
        let bodyEnd = buf.index(bodyStart, offsetBy: length)
        let body = Data(buf[bodyStart..<bodyEnd])
        buf = Data(buf[bodyEnd...])
        let path = start.count > 1 ? String(start[1].split(separator: "?").first ?? "") : "/"
        return HTTPRequest(method: start.first.map(String.init) ?? "", path: path, body: body)
    }

    private func respond(_ c: NWConnection, _ r: HTTPResponse) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found"][r.status] ?? "OK"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Length: \(r.body.count)\r\nConnection: keep-alive\r\n"
        if !r.body.isEmpty { head += "Content-Type: \(r.contentType)\r\n" }
        c.send(content: Data((head + "\r\n").utf8) + r.body, completion: .idempotent)
    }
}
