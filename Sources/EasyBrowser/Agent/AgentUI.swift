import SwiftUI
import AppKit
import Observation

/// Что агент сейчас делает — для индикатора поверх страницы.
@MainActor
@Observable
final class AgentActivity {
    static let shared = AgentActivity()

    private(set) var tabID: UUID?
    private(set) var action = ""
    private var generation = 0

    func mark(tabID: UUID, action: String) {
        self.tabID = tabID
        self.action = String(action.prefix(80))
        generation += 1
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.generation == current else { return }
            self.tabID = nil
        }
    }
}

/// Рамка и плашка «Агент управляет вкладкой» поверх страницы, пока агент работает с ней.
struct AgentActivityOverlay: View {
    let tabID: UUID
    private var activity = AgentActivity.shared

    init(tabID: UUID) {
        self.tabID = tabID
    }

    var body: some View {
        let active = activity.tabID == tabID
        ZStack(alignment: .bottom) {
            if active {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 3)
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse)
                    Text("Агент управляет вкладкой")
                        .fontWeight(.semibold)
                    if !activity.action.isEmpty {
                        Text("· \(activity.action)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, 14)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: active)
        .allowsHitTesting(false)
    }
}

/// Настройки → Агенты.
struct AgentSettingsPane: View {
    @AppStorage(AgentServer.enabledKey) private var enabled = false
    @AppStorage(AgentServer.portKey) private var storedPort = AgentServer.defaultPort
    @State private var portText = ""
    @State private var token = ""
    @State private var revealToken = false
    @State private var state: AgentServer.State = .stopped
    @State private var copied: String?

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aircraft-mcp").path
    }

    private var httpCommand: String {
        "claude mcp add --transport http aircraft \(AgentServer.endpointURL) --header \"Authorization: Bearer \(token)\""
    }

    private var stdioCommand: String {
        "claude mcp add aircraft -- \"\(cliPath)\""
    }

    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "aircraft": {
              "command": "\(cliPath)"
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Разрешить агентам управлять браузером")
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                    }
                    Spacer()
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.vertical, 2)

                HStack {
                    Text("Порт")
                    Spacer()
                    TextField("", text: $portText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyPort)
                    Button("Применить", action: applyPort)
                        .disabled(Int(portText) == storedPort)
                }
            } header: {
                Text("MCP-сервер")
            } footer: {
                Text("Агенты подключаются по протоколу MCP к \(AgentServer.endpointURL). Сервер слушает только этот компьютер и пускает лишь тех, у кого есть токен. Агент работает в ваших вкладках с вашими входами на сайты — включайте только для агентов, которым доверяете.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(revealToken ? token : String(repeating: "•", count: 24))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button { revealToken.toggle() } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealToken ? "Скрыть" : "Показать")
                    copyButton("token", token)
                    Button("Новый токен") {
                        token = AgentServer.regenerateToken()
                        AgentServer.shared.applySettings()
                    }
                }
            } header: {
                Text("Токен доступа")
            } footer: {
                Text("Новый токен сразу отключает всех подключённых агентов. aircraft-mcp подхватывает его сам.")
                    .foregroundStyle(.secondary)
            }

            Section {
                commandRow("Claude Code (через aircraft-mcp)", stdioCommand, id: "stdio")
                commandRow("Claude Code (напрямую по HTTP)", httpCommand, id: "http")
                commandRow("Claude Desktop, Cursor и другие (JSON)", jsonConfig, id: "json")
            } header: {
                Text("Подключение")
            } footer: {
                Text("aircraft-mcp сам находит запущенный Aircraft и при необходимости запускает его. Если перенесёте Aircraft.app в другую папку, обновите путь в настройках агента.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            portText = String(AgentServer.port)
            token = AgentServer.token
            state = AgentServer.shared.state
        }
        .onChange(of: enabled) { _, _ in AgentServer.shared.applySettings() }
        .onReceive(NotificationCenter.default.publisher(for: .agentServerStateDidChange)) { _ in
            state = AgentServer.shared.state
        }
    }

    private var statusText: String {
        switch state {
        case .stopped: "Выключено"
        case .starting: "Запускается…"
        case .running(let port): "Работает на 127.0.0.1:\(port)"
        case .failed(let message): "Ошибка: \(message)"
        }
    }

    private var statusColor: Color {
        switch state {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func applyPort() {
        guard let port = Int(portText), (1024...65535).contains(port) else {
            portText = String(AgentServer.port)
            return
        }
        storedPort = port
        AgentServer.shared.applySettings()
    }

    private func commandRow(_ title: String, _ command: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                copyButton(id, command)
            }
            Text(id == "http" && !revealToken ? command.replacingOccurrences(of: token, with: "••••") : command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func copyButton(_ id: String, _ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if copied == id { copied = nil }
            }
        } label: {
            Image(systemName: copied == id ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Скопировать")
    }
}
