import Foundation

// aircraft-mcp — MCP-сервер для stdio-клиентов (Claude Code, Claude Desktop, Cursor…).
//
// Сам ничего не делает с браузером: читает JSON-RPC сообщения построчно из stdin,
// пересылает их во встроенный HTTP MCP-сервер Aircraft и пишет ответы в stdout.
// Адрес и токен берутся из ~/Library/Application Support/Aircraft/agent.json,
// который Aircraft пишет при запуске сервера. Если Aircraft не запущен, он запускается.
//
// Переопределения: AIRCRAFT_MCP_URL и AIRCRAFT_MCP_TOKEN.

struct Endpoint: Sendable {
    let url: URL
    let token: String
}

enum BridgeError: Error, CustomStringConvertible {
    case notRunning
    case disabled
    case http(Int, String)

    var description: String {
        switch self {
        case .notRunning:
            "Aircraft is not running and could not be started."
        case .disabled:
            "Aircraft is running, but agent access is off. Turn it on in Aircraft → Settings → Agents."
        case .http(let status, let body):
            "Aircraft returned HTTP \(status): \(body)"
        }
    }
}

let bundleIdentifier = "com.taras.aircraft"
let discoveryFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Aircraft/agent.json")

func log(_ message: String) {
    FileHandle.standardError.write(Data("aircraft-mcp: \(message)\n".utf8))
}

func readEndpoint() -> Endpoint? {
    let environment = ProcessInfo.processInfo.environment
    if let rawURL = environment["AIRCRAFT_MCP_URL"], let url = URL(string: rawURL),
       let token = environment["AIRCRAFT_MCP_TOKEN"] {
        return Endpoint(url: url, token: token)
    }
    guard let data = try? Data(contentsOf: discoveryFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawURL = object["url"] as? String, let url = URL(string: rawURL),
          let token = object["token"] as? String else { return nil }
    if let pid = object["pid"] as? Int32, kill(pid, 0) != 0, errno == ESRCH { return nil } // устаревший файл
    return Endpoint(url: url, token: token)
}

func isAircraftRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "Aircraft"]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Ищем Aircraft.app, в который вложен этот бинарник, иначе запускаем по bundle id.
func launchAircraft() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" {
        process.arguments = ["-g", bundle.path]
    } else {
        process.arguments = ["-g", "-b", bundleIdentifier]
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

actor Connection {
    private var endpoint: Endpoint?
    private var launchAttempted = false

    func current() async throws -> Endpoint {
        if let endpoint { return endpoint }
        if let found = readEndpoint() {
            endpoint = found
            return found
        }
        let running = isAircraftRunning()
        if !running, !launchAttempted {
            launchAttempted = true
            log("starting Aircraft…")
            launchAircraft()
        }
        // Ждём, пока Aircraft поднимет сервер и запишет agent.json.
        for _ in 0..<(running ? 4 : 50) {
            try await Task.sleep(for: .milliseconds(200))
            if let found = readEndpoint() {
                endpoint = found
                return found
            }
        }
        throw isAircraftRunning() ? BridgeError.disabled : BridgeError.notRunning
    }

    /// Порт или токен могли смениться (перезапуск, новый токен) — перечитываем файл.
    func invalidate() {
        endpoint = nil
    }
}

actor Output {
    func write(_ data: Data) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

let connection = Connection()
let output = Output()

let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 120
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
}()

func post(_ body: Data, to endpoint: Endpoint) async throws -> (Int, Data) {
    var request = URLRequest(url: endpoint.url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

func forward(_ line: String) async {
    let body = Data(line.utf8)
    let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"]
    do {
        var attempt = 0
        while true {
            attempt += 1
            let endpoint = try await connection.current()
            do {
                let (status, data) = try await post(body, to: endpoint)
                if status == 202 || (status == 200 && data.isEmpty) { return }
                if status == 200 {
                    await output.write(data)
                    return
                }
                if status == 401, attempt == 1 {
                    await connection.invalidate()
                    continue
                }
                throw BridgeError.http(status, String(decoding: data, as: UTF8.self))
            } catch let error as URLError where attempt == 1 {
                // Aircraft перезапустился или сменил порт.
                log("connection failed (\(error.code.rawValue)), retrying")
                await connection.invalidate()
                continue
            }
        }
    } catch {
        log("\(error)")
        guard let id, !(id is NSNull) else { return }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32000, "message": "\(error)"]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            await output.write(data)
        }
    }
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    aircraft-mcp — connects MCP clients over stdio to the Aircraft browser.

    Usage in Claude Code:
      claude mcp add aircraft -- \(CommandLine.arguments[0])

    Turn on Aircraft → Settings → Agents first. Environment overrides:
      AIRCRAFT_MCP_URL, AIRCRAFT_MCP_TOKEN
    """)
    exit(0)
}

// Запросы обрабатываются параллельно: долгий browser_wait_for не блокирует остальные.
await withTaskGroup(of: Void.self) { group in
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            group.addTask { await forward(trimmed) }
        }
    } catch {
        log("stdin error: \(error)")
    }
    await group.waitForAll()
}
