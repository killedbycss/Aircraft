import Foundation

enum URLRouter {
    static func normalizedPrefix(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, !value.contains(" ") else { return nil }

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard let url = URL(string: value), url.host != nil else { return nil }
            return value
        }

        guard let url = URL(string: "https://\(value)"), url.host != nil else { return nil }
        return value
    }

    static func prefixedTarget(query: String, prefix: String) -> String? {
        guard let prefix = normalizedPrefix(prefix) else { return nil }
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = prefix.hasPrefix("http") ? prefix : "https://\(prefix)"
        guard !rawQuery.isEmpty else { return base }

        var path = rawQuery
        if let url = URL(string: rawQuery), url.scheme != nil, url.host != nil {
            path = url.path
            if let query = url.query, !query.isEmpty { path += "?\(query)" }
        } else {
            let components = rawQuery.split(separator: "/", omittingEmptySubsequences: true)
            if let first = components.first, first.contains(".") {
                path = components.dropFirst().joined(separator: "/")
            }
        }

        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return path.isEmpty ? base : "\(base)/\(path)"
    }

    /// Локальный сервер без схемы: «:3000», «localhost:5173/app», «127.0.0.1:8080»,
    /// «myapp.localhost», «printer.local». Такие адреса открываются по http:
    /// иначе «localhost:3000» читался как схема «localhost:», а 127.0.0.1 — как https.
    static func localTarget(_ value: String) -> String? {
        guard !value.contains(" "), !value.contains("://") else { return nil }
        if value.hasPrefix(":"), let port = Int(value.dropFirst().prefix { $0.isNumber }), (1...65535).contains(port) {
            return "http://localhost" + value
        }
        let hostPart = value.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        var host = String(hostPart)
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[...close])
        } else if let colon = host.lastIndex(of: ":") {
            guard Int(host[host.index(after: colon)...]) != nil else { return nil }
            host = String(host[..<colon])
        }
        return LocalDevelopment.isLocalHost(host) ? "http://" + value : nil
    }

    static func searchTarget(query: String, template: String) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let encoded = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }

        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else { return nil }
        let replacements = ["{query}", "%s", "%@"]
        if let token = replacements.first(where: { trimmedTemplate.contains($0) }) {
            let target = trimmedTemplate.replacingOccurrences(of: token, with: encoded)
            return URL(string: target)?.scheme == nil ? nil : target
        }

        let separator = trimmedTemplate.contains("?") ? "&" : "?"
        let target = "\(trimmedTemplate)\(separator)q=\(encoded)"
        return URL(string: target)?.scheme == nil ? nil : target
    }

    static func navigationTarget(input: String, searchTemplate: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let local = localTarget(value) { return local }
        if let url = URL(string: value), url.scheme != nil { return value }
        if value.contains("."), !value.contains(" ") { return "https://\(value)" }
        return searchTarget(query: value, template: searchTemplate)
    }
}
