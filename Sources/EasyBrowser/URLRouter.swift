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
        if let url = URL(string: value), url.scheme != nil { return value }
        if value.contains("."), !value.contains(" ") { return "https://\(value)" }
        return searchTarget(query: value, template: searchTemplate)
    }
}
