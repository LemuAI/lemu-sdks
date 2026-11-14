import Foundation
import Network

/// A fake ingest server on 127.0.0.1: records each request and answers with
/// the next scripted status (204 when the script is empty). One request per
/// connection (`Connection: close`).
final class LocalIngestServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "lemu.tests.ingest")
    private let lock = NSLock()
    private var script: [Int] = []
    private var recorded: [RecordedRequest] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw NSError(domain: "LocalIngestServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not start"])
        }
        self.port = port
    }

    var baseURL: String { return "http://127.0.0.1:\(port)" }

    func enqueue(_ statuses: Int...) {
        lock.lock(); defer { lock.unlock() }
        script.append(contentsOf: statuses)
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let request = self.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Returns a request once the headers and the full body have arrived.
    private func parse(_ buffer: Data) -> RecordedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex ..< headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = buffer[bodyStart ..< bodyStart + length]
        return RecordedRequest(
            method: requestLine.first.map(String.init) ?? "",
            path: requestLine.count > 1 ? String(requestLine[1]) : "",
            headers: headers,
            body: Data(body)
        )
    }

    private func respond(to request: RecordedRequest, on connection: NWConnection) {
        lock.lock()
        recorded.append(request)
        let status = script.isEmpty ? 204 : script.removeFirst()
        lock.unlock()
        let response = "HTTP/1.1 \(status) Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
