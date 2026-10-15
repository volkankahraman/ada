import Foundation
import Network

/// One hook process waiting on the other end of the socket (a `curl` call).
final class HookClient {
    private let conn: NWConnection
    private var replied = false
    /// Fires if the hook process goes away before we answer (user answered in the terminal, Ctrl-C, timeout).
    var onClose: (() -> Void)?

    init(_ conn: NWConnection) { self.conn = conn }

    func reply(_ body: Data = Data()) {
        guard !replied else { return }
        replied = true
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    func closed() {
        guard !replied else { return }
        replied = true
        onClose?()
        conn.cancel()
    }
}

/// Minimal HTTP over a unix socket. Hooks call it with `curl --unix-socket`, so no bridge binary is needed.
/// ponytail: hand-rolled HTTP parsing, only handles what curl sends (Content-Length bodies, no chunking).
final class HookServer {
    private let listener: NWListener
    var onRequest: ((_ headers: [String: String], _ body: Data, HookClient) -> Void)?

    init(path: String) throws {
        unlink(path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: chmod(path, 0o600) // only this user may talk to the island
            case .failed(let e): NSLog("ada: listener failed: \(e)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: .main)
    }

    private func accept(_ conn: NWConnection) {
        let client = HookClient(conn)
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: client.closed()
            default: break
            }
        }
        conn.start(queue: .main)
        read(conn, client, Data())
    }

    private func read(_ conn: NWConnection, _ client: HookClient, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            var buf = buf
            if let data { buf.append(data) }
            if let (headers, body) = Self.parse(buf) {
                self?.onRequest?(headers, body, client)
                Self.watchClose(conn, client)
            } else if done || err != nil {
                client.closed()
            } else {
                self?.read(conn, client, buf)
            }
        }
    }

    /// Keep reading so we notice when curl hangs up while a permission is still pending.
    private static func watchClose(_ conn: NWConnection, _ client: HookClient) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, done, err in
            if done || err != nil { client.closed() } else { watchClose(conn, client) }
        }
    }

    static func parse(_ buf: Data) -> ([String: String], Data)? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var headers: [String: String] = [:]
        for line in String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let body = buf[end.upperBound...]
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard body.count >= length else { return nil }
        return (headers, Data(body.prefix(length)))
    }
}
