import Foundation
import Network
import Security

/// Встроенный MCP-сервер: агенты (Claude Code, Cursor и другие MCP-клиенты) управляют
/// браузером по HTTP на 127.0.0.1. Транспорт — MCP Streamable HTTP без SSE:
/// каждый POST /mcp несёт JSON-RPC сообщение и получает JSON-ответ.
///
/// Безопасность: сервер выключен по умолчанию, слушает только loopback, требует
/// Bearer-токен и отклоняет запросы со сторонним Origin (защита от DNS rebinding
/// и от страниц, которые пытаются достучаться до localhost).
@MainActor
final class AgentServer {
    static let shared = AgentServer()

    static let enabledKey = "agentServerEnabled"
    static let portKey = "agentServerPort"
    static let tokenKey = "agentServerToken"
    static let defaultPort = 7777

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var port: Int {
        let value = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65535).contains(value) ? value : defaultPort
    }

    static var token: String {
        if let token = UserDefaults.standard.string(forKey: tokenKey), token.count >= 32 { return token }
        return regenerateToken()
    }

    @discardableResult
    static func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: tokenKey)
        return token
    }

    /// Файл, по которому `aircraft-mcp` находит порт и токен запущенного браузера.
    static var discoveryFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aircraft/agent.json")
    }

    static var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var state: State = .stopped {
        didSet { NotificationCenter.default.post(name: .agentServerStateDidChange, object: nil) }
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: AgentHTTPConnection] = [:]
    private let handler = AgentMCPHandler()

    /// Запускает или останавливает сервер по текущим настройкам.
    func applySettings() {
        stop()
        if Self.isEnabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(Self.port)) else {
            state = .failed("Неверный порт")
            return
        }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] newState in
                MainActor.assumeIsolated { self?.listenerStateChanged(newState) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            state = .starting
            listener.start(queue: .main)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        removeDiscoveryFile()
        if state != .stopped { state = .stopped }
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            state = .running(port: Self.port)
            writeDiscoveryFile()
        case .failed(let error):
            let message: String
            if case .posix(let code) = error, code == .EADDRINUSE {
                message = "Порт \(Self.port) занят другой программой"
            } else {
                message = error.localizedDescription
            }
            stop()
            state = .failed(message)
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = AgentHTTPConnection(connection: nwConnection) { [weak self] request in
            guard let self else { return AgentHTTPResponse(status: 503) }
            return await self.respond(to: request)
        }
        let key = ObjectIdentifier(connection)
        connection.onClose = { [weak self] in self?.connections.removeValue(forKey: key) }
        connections[key] = connection
        connection.start()
    }

    private func respond(to request: AgentHTTPRequest) async -> AgentHTTPResponse {
        if let origin = request.headers["origin"], !Self.isLocalOrigin(origin) {
            return AgentHTTPResponse(status: 403, json: ["error": "Forbidden origin"])
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard path == "/mcp" || path == "/mcp/" else {
            return AgentHTTPResponse(status: 404, json: ["error": "Not found. MCP endpoint is /mcp"])
        }
        guard Self.isAuthorized(request.headers["authorization"]) else {
            return AgentHTTPResponse(status: 401, json: ["error": "Missing or invalid bearer token"])
        }
        switch request.method {
        case "POST":
            guard let body = await handler.handle(request.body) else {
                return AgentHTTPResponse(status: 202)
            }
            return AgentHTTPResponse(status: 200, contentType: "application/json", body: body)
        case "DELETE":
            return AgentHTTPResponse(status: 200)
        default:
            // Сервер не открывает SSE-поток для уведомлений — это допускается спецификацией.
            return AgentHTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
    }

    private static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let presented = Array(header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else { return false }
        // Сравнение без раннего выхода, чтобы токен нельзя было подобрать по времени ответа.
        var difference: UInt8 = 0
        for index in expected.indices { difference |= presented[index] ^ expected[index] }
        return difference == 0
    }

    private func writeDiscoveryFile() {
        let url = Self.discoveryFileURL
        let info: [String: Any] = [
            "url": Self.endpointURL,
            "port": Self.port,
            "token": Self.token,
            "pid": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Aircraft MCP: не удалось записать %@: %@", url.path, error.localizedDescription)
        }
    }

    private func removeDiscoveryFile() {
        try? FileManager.default.removeItem(at: Self.discoveryFileURL)
    }
}

extension Notification.Name {
    static let agentServerStateDidChange = Notification.Name("AgentServerStateDidChange")
}

// MARK: - HTTP

struct AgentHTTPRequest {
    var method: String
    var path: String
    /// Заголовки с именами в нижнем регистре.
    var headers: [String: String]
    var body: Data
}

struct AgentHTTPResponse {
    var status: Int
    var contentType: String = "application/json"
    var headers: [String: String] = [:]
    var body = Data()

    init(status: Int, contentType: String = "application/json", headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    init(status: Int, json: [String: Any]) {
        self.init(status: status, body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// Одно HTTP/1.1 соединение: читает один запрос, отвечает и закрывается.
@MainActor
final class AgentHTTPConnection {
    private static let maxBodySize = 16 * 1024 * 1024

    private let connection: NWConnection
    private let handler: (AgentHTTPRequest) async -> AgentHTTPResponse
    private var buffer = Data()
    private var finished = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, handler: @escaping (AgentHTTPRequest) async -> AgentHTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if self.tryHandleRequest() { return }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    /// Возвращает true, если запрос собран целиком и передан на обработку.
    private func tryHandleRequest() -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            if buffer.count > 64 * 1024 { send(AgentHTTPResponse(status: 400)); return true }
            return false
        }
        guard let headerText = String(data: buffer[buffer.startIndex..<headerRange.lowerBound], encoding: .utf8) else {
            send(AgentHTTPResponse(status: 400))
            return true
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { send(AgentHTTPResponse(status: 400)); return true }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maxBodySize else { send(AgentHTTPResponse(status: 413)); return true }
        let bodyStart = headerRange.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return false }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        let request = AgentHTTPRequest(method: String(requestLine[0]).uppercased(), path: String(requestLine[1]), headers: headers, body: body)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let response = await self.handler(request)
            self.send(response)
        }
        return true
    }

    private func send(_ response: AgentHTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connection.cancel()
                self?.close()
            }
        })
    }

    private func close() {
        guard !finished else { return }
        finished = true
        onClose?()
        onClose = nil
    }
}
