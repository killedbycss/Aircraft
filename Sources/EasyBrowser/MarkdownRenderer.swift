import Foundation

/// Markdown → HTML без зависимостей: CommonMark-подмножество плюс GFM
/// (таблицы, списки задач, зачёркивание, автоссылки). Сырой HTML пропускается —
/// скрипты в нём блокирует Content-Security-Policy страницы просмотрщика.
struct MarkdownRenderer {
    struct Heading: Equatable {
        var level: Int
        var text: String
        var id: String
    }

    private(set) var headings: [Heading] = []
    private var references: [String: (url: String, title: String?)] = [:]
    private var usedIDs: [String: Int] = [:]

    static func render(_ markdown: String) -> (html: String, headings: [Heading]) {
        var renderer = MarkdownRenderer()
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        var lines = normalized.components(separatedBy: "\n")
        renderer.collectReferences(&lines)
        let html = renderer.renderBlocks(lines)
        return (html, renderer.headings)
    }

    // MARK: Ссылки-сноски `[id]: url "title"`

    private mutating func collectReferences(_ lines: inout [String]) {
        let pattern = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s+["'(](.+)["')])?\s*$"#)
        var inFence = false
        lines = lines.filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                inFence.toggle()
            }
            guard !inFence else { return true }
            let ns = line as NSString
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return true }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let url = ns.substring(with: match.range(at: 2))
            let title = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
            references[key] = (url, title)
            return false
        }
    }

    // MARK: Блоки

    private mutating func renderBlocks(_ lines: [String]) -> String {
        var output = ""
        var index = 0
        var paragraph: [String] = []

        func flushParagraph(_ renderer: inout MarkdownRenderer) {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            output += "<p>\(renderer.inline(text))</p>\n"
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph(&self)
                index += 1
                continue
            }

            // Блок кода ``` или ~~~
            if let fence = Self.fenceMarker(trimmed) {
                flushParagraph(&self)
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let langAttribute = language.isEmpty ? "" : " class=\"language-\(Self.escape(language))\" data-lang=\"\(Self.escape(language))\""
                output += "<pre><code\(langAttribute)>\(Self.escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Код с отступом (4 пробела) — только не внутри абзаца.
            if paragraph.isEmpty, line.hasPrefix("    ") {
                var code: [String] = []
                while index < lines.count, lines[index].hasPrefix("    ") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[index].dropFirst(min(4, lines[index].count))))
                    index += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                output += "<pre><code>\(Self.escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Заголовок #
            if let heading = Self.atxHeading(trimmed) {
                flushParagraph(&self)
                output += headingHTML(level: heading.level, text: heading.text)
                index += 1
                continue
            }

            // Заголовок с подчёркиванием === / ---
            if !paragraph.isEmpty, paragraph.count == 1, Self.isSetextUnderline(trimmed) {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                output += headingHTML(level: level, text: paragraph[0])
                paragraph = []
                index += 1
                continue
            }

            // Горизонтальная линия
            if Self.isRule(trimmed) {
                flushParagraph(&self)
                output += "<hr>\n"
                index += 1
                continue
            }

            // Цитата
            if trimmed.hasPrefix(">") {
                flushParagraph(&self)
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if current.hasPrefix(">") {
                        var content = String(current.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        quoted.append(content)
                    } else if !current.isEmpty, !quoted.isEmpty, !(quoted.last ?? "").isEmpty {
                        quoted.append(current) // ленивое продолжение
                    } else {
                        break
                    }
                    index += 1
                }
                output += "<blockquote>\n\(renderBlocks(quoted))</blockquote>\n"
                continue
            }

            // Таблица
            if index + 1 < lines.count, trimmed.contains("|"), Self.isTableSeparator(lines[index + 1]) {
                flushParagraph(&self)
                let header = Self.tableCells(trimmed)
                let alignments = Self.tableCells(lines[index + 1]).map(Self.alignment)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.tableCells(lines[index]))
                    index += 1
                }
                output += "<table>\n<thead><tr>"
                for (column, cell) in header.enumerated() {
                    output += "<th\(Self.alignAttribute(alignments, column))>\(inline(cell))</th>"
                }
                output += "</tr></thead>\n<tbody>\n"
                for row in rows {
                    output += "<tr>"
                    for column in 0..<header.count {
                        let cell = column < row.count ? row[column] : ""
                        output += "<td\(Self.alignAttribute(alignments, column))>\(inline(cell))</td>"
                    }
                    output += "</tr>\n"
                }
                output += "</tbody></table>\n"
                continue
            }

            // Список
            if Self.listMarker(line) != nil {
                flushParagraph(&self)
                let (html, next) = renderList(lines, from: index)
                output += html
                index = next
                continue
            }

            // HTML-блок: строка начинается с тега — выводим как есть до пустой строки.
            if paragraph.isEmpty, trimmed.hasPrefix("<"), Self.startsWithHTMLTag(trimmed) {
                var block: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    block.append(lines[index])
                    index += 1
                }
                output += block.joined(separator: "\n") + "\n"
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph(&self)
        return output
    }

    private mutating func headingHTML(level: Int, text: String) -> String {
        let plain = Self.plainText(text)
        var id = Self.slug(plain)
        if let count = usedIDs[id] {
            usedIDs[id] = count + 1
            id += "-\(count)"
        } else {
            usedIDs[id] = 1
        }
        headings.append(Heading(level: level, text: plain, id: id))
        return "<h\(level) id=\"\(id)\"><a class=\"anchor\" href=\"#\(id)\">#</a>\(inline(text))</h\(level)>\n"
    }

    // MARK: Списки

    private struct ListMarker {
        var ordered: Bool
        var start: Int
        var indent: Int
        var contentOffset: Int
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            if isRule(String(rest)) { return nil }
            return ListMarker(ordered: false, start: 1, indent: indent, contentOffset: indent + 2)
        }
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
        let tail = after.dropFirst()
        guard tail.isEmpty || tail.first == " " else { return nil }
        return ListMarker(ordered: true, start: Int(digits) ?? 1, indent: indent, contentOffset: indent + digits.count + 2)
    }

    private mutating func renderList(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = Self.listMarker(lines[start]) else { return ("", start + 1) }
        var index = start
        var items: [[String]] = []
        var loose = false

        while index < lines.count {
            let line = lines[index]
            if let marker = Self.listMarker(line), marker.indent < first.contentOffset, marker.ordered == first.ordered {
                // Новый пункт этого списка.
                items.append([String(line.dropFirst(min(marker.contentOffset, line.count)))])
                index += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Пустая строка: список продолжается, если дальше идёт пункт или текст с отступом.
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                let nextIndent = next.prefix(while: { $0 == " " }).count
                if let marker = Self.listMarker(next), marker.indent < first.contentOffset, marker.ordered == first.ordered {
                    loose = true
                    items[items.count - 1].append("")
                    index += 1
                    continue
                }
                if !next.trimmingCharacters(in: .whitespaces).isEmpty, nextIndent >= first.contentOffset {
                    items[items.count - 1].append("")
                    index += 1
                    continue
                }
                break
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent >= first.contentOffset || Self.listMarker(line) != nil {
                items[items.count - 1].append(String(line.dropFirst(min(first.contentOffset, indent))))
                index += 1
                continue
            }
            if Self.listMarker(line) == nil, !Self.isRule(line.trimmingCharacters(in: .whitespaces)),
               !(items.last?.last ?? "").isEmpty {
                // Ленивое продолжение абзаца пункта.
                items[items.count - 1].append(line.trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }
            break
        }

        let tag = first.ordered ? "ol" : "ul"
        let startAttribute = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        var html = "<\(tag)\(startAttribute)>\n"
        for item in items {
            var content = item
            var checkbox = ""
            if let firstLine = content.first {
                let lower = firstLine.lowercased()
                if lower.hasPrefix("[ ] ") || lower.hasPrefix("[x] ") {
                    let checked = lower.hasPrefix("[x]")
                    checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                    content[0] = String(firstLine.dropFirst(4))
                }
            }
            let inner = renderBlocks(content)
            var body = inner
            if !loose, inner.hasPrefix("<p>") {
                // Плотный список: первый абзац без <p>.
                if let end = inner.range(of: "</p>\n") {
                    body = String(inner[inner.index(inner.startIndex, offsetBy: 3)..<end.lowerBound]) + "\n" + inner[end.upperBound...]
                }
            }
            html += "<li\(checkbox.isEmpty ? "" : " class=\"task\"")>\(checkbox)\(body)</li>\n"
        }
        html += "</\(tag)>\n"
        return (html, index)
    }

    // MARK: Строчная разметка

    mutating func inline(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var index = 0

        func peek(_ offset: Int) -> Character? {
            let target = index + offset
            return target < chars.count ? chars[target] : nil
        }

        while index < chars.count {
            let char = chars[index]

            // Экранирование
            if char == "\\", let next = peek(1) {
                if next == "\n" { result += "<br>\n"; index += 2; continue }
                if "\\`*_{}[]()#+-.!|~<>".contains(next) {
                    result += Self.escape(String(next))
                    index += 2
                    continue
                }
            }

            // Код
            if char == "`" {
                let ticks = chars[index...].prefix(while: { $0 == "`" }).count
                let marker = String(repeating: "`", count: ticks)
                let rest = String(chars[(index + ticks)...])
                if let close = rest.range(of: marker) {
                    var code = String(rest[..<close.lowerBound])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 1 { code = String(code.dropFirst().dropLast()) }
                    result += "<code>\(Self.escape(code))</code>"
                    index += ticks + rest.distance(from: rest.startIndex, to: close.upperBound)
                    continue
                }
                result += marker
                index += ticks
                continue
            }

            // Картинка и ссылка
            if char == "!" && peek(1) == "[" || char == "[" {
                let isImage = char == "!"
                let open = isImage ? index + 1 : index
                if let (label, labelEnd) = Self.bracket(chars, from: open, open: "[", close: "]") {
                    var destination: (url: String, title: String?)?
                    var end = labelEnd + 1
                    if labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(",
                       let (inside, parenEnd) = Self.bracket(chars, from: labelEnd + 1, open: "(", close: ")") {
                        destination = Self.parseDestination(inside)
                        end = parenEnd + 1
                    } else if labelEnd + 1 < chars.count, chars[labelEnd + 1] == "[",
                              let (ref, refEnd) = Self.bracket(chars, from: labelEnd + 1, open: "[", close: "]") {
                        let key = (ref.isEmpty ? label : ref).lowercased()
                        if let found = references[key] {
                            destination = found
                            end = refEnd + 1
                        }
                    } else if let found = references[label.lowercased()] {
                        destination = found
                    }
                    if let destination {
                        let url = Self.escape(Self.safeURL(destination.url))
                        let title = destination.title.map { " title=\"\(Self.escape($0))\"" } ?? ""
                        if isImage {
                            result += "<img src=\"\(url)\" alt=\"\(Self.escape(Self.plainText(label)))\"\(title) loading=\"lazy\">"
                        } else {
                            result += "<a href=\"\(url)\"\(title)>\(inline(label))</a>"
                        }
                        index = end
                        continue
                    }
                }
            }

            // Автоссылка <https://…>
            if char == "<" {
                let rest = String(chars[(index + 1)...])
                if let close = rest.firstIndex(of: ">") {
                    let inside = String(rest[..<close])
                    if inside.hasPrefix("http://") || inside.hasPrefix("https://") || inside.hasPrefix("mailto:"), !inside.contains(" ") {
                        result += "<a href=\"\(Self.escape(inside))\">\(Self.escape(inside))</a>"
                        index += inside.count + 2
                        continue
                    }
                    // Строчный HTML-тег пропускаем как есть.
                    if Self.startsWithHTMLTag("<" + inside + ">") {
                        result += "<" + inside + ">"
                        index += inside.count + 2
                        continue
                    }
                }
                result += "&lt;"
                index += 1
                continue
            }

            // Голые ссылки (GFM)
            if char == "h", (String(chars[index...].prefix(8)) == "https://" || String(chars[index...].prefix(7)) == "http://"),
               index == 0 || " (\n".contains(chars[index - 1]) {
                var end = index
                while end < chars.count, !" \n<>\"".contains(chars[end]) { end += 1 }
                while end > index, ".,;:!?)".contains(chars[end - 1]) { end -= 1 }
                let link = String(chars[index..<end])
                result += "<a href=\"\(Self.escape(link))\">\(Self.escape(link))</a>"
                index = end
                continue
            }

            // Зачёркивание ~~
            if char == "~", peek(1) == "~", let close = Self.findClosing(chars, from: index + 2, marker: "~~") {
                result += "<del>\(inline(String(chars[(index + 2)..<close])))</del>"
                index = close + 2
                continue
            }

            // Жирный ** или __
            if (char == "*" || char == "_"), peek(1) == char {
                let marker = String([char, char])
                if let close = Self.findClosing(chars, from: index + 2, marker: marker), close > index + 2,
                   char == "*" || Self.isWordBoundary(chars, index - 1) {
                    result += "<strong>\(inline(String(chars[(index + 2)..<close])))</strong>"
                    index = close + 2
                    continue
                }
            }

            // Курсив * или _
            if char == "*" || char == "_" {
                if let next = peek(1), next != " ", let close = Self.findClosing(chars, from: index + 1, marker: String(char)),
                   close > index + 1, chars[close - 1] != " ",
                   char == "*" || (Self.isWordBoundary(chars, index - 1) && Self.isWordBoundary(chars, close + 1)) {
                    result += "<em>\(inline(String(chars[(index + 1)..<close])))</em>"
                    index = close + 1
                    continue
                }
            }

            // Перенос строки: два пробела в конце
            if char == "\n" {
                result += result.hasSuffix("  ") ? "<br>\n" : "\n"
                index += 1
                continue
            }

            result += Self.escape(String(char))
            index += 1
        }
        return result
    }

    // MARK: Вспомогательное

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for char in value {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(char)
            }
        }
        return result
    }

    /// `javascript:` и подобные схемы в ссылках не допускаются.
    static func safeURL(_ value: String) -> String {
        let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
        return value
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        for char in lowered {
            if char.isLetter || char.isNumber { result.append(char) }
            else if char == " " || char == "-" || char == "_" { result.append("-") }
        }
        return result.isEmpty ? "section" : result
    }

    static func plainText(_ markdown: String) -> String {
        var value = markdown
        for marker in ["**", "__", "~~", "`", "*", "_"] { value = value.replacingOccurrences(of: marker, with: "") }
        let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
        value = link.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: "$1")
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let count = trimmed.prefix(while: { $0 == marker.first }).count
            return String(repeating: String(marker.first!), count: count)
        }
        return nil
    }

    private static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return false }
        let cells = tableCells(trimmed)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value.allSatisfy { $0 == "-" || $0 == ":" } && value.contains("-")
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|"), !value.hasSuffix("\\|") { value.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in value {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; current.append(char); continue }
            if char == "`" { inCode.toggle() }
            if char == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignment(_ cell: String) -> String? {
        let value = cell.trimmingCharacters(in: .whitespaces)
        switch (value.hasPrefix(":"), value.hasSuffix(":")) {
        case (true, true): return "center"
        case (false, true): return "right"
        case (true, false): return "left"
        default: return nil
        }
    }

    private static func alignAttribute(_ alignments: [String?], _ column: Int) -> String {
        guard column < alignments.count, let value = alignments[column] else { return "" }
        return " style=\"text-align:\(value)\""
    }

    private static let htmlTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "center", "code", "dd", "del", "details", "div", "dl", "dt", "em", "figcaption",
        "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "picture",
        "pre", "s", "samp", "source", "span", "strong", "sub", "summary", "sup", "table", "tbody", "td", "th", "thead",
        "tr", "u", "ul", "video", "!--"
    ]

    static func startsWithHTMLTag(_ text: String) -> Bool {
        guard text.hasPrefix("<") else { return false }
        if text.hasPrefix("<!--") { return true }
        let name = text.dropFirst().drop(while: { $0 == "/" })
            .prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
        return htmlTags.contains(name)
    }

    private static func bracket(_ chars: [Character], from start: Int, open: Character, close: Character) -> (String, Int)? {
        guard start < chars.count, chars[start] == open else { return nil }
        var depth = 0
        var index = start
        while index < chars.count {
            let char = chars[index]
            if char == "\\" { index += 2; continue }
            if char == open { depth += 1 }
            if char == close {
                depth -= 1
                if depth == 0 { return (String(chars[(start + 1)..<index]), index) }
            }
            index += 1
        }
        return nil
    }

    private static func parseDestination(_ inside: String) -> (url: String, title: String?) {
        let value = inside.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("<"), let close = value.firstIndex(of: ">") {
            return (String(value[value.index(after: value.startIndex)..<close]), nil)
        }
        if let space = value.firstIndex(of: " ") {
            let url = String(value[..<space])
            var title = value[space...].trimmingCharacters(in: .whitespaces)
            if title.count >= 2, let first = title.first, "\"'(".contains(first) {
                title = String(title.dropFirst().dropLast())
            }
            return (url, title)
        }
        return (value, nil)
    }

    private static func findClosing(_ chars: [Character], from start: Int, marker: String) -> Int? {
        let markerChars = Array(marker)
        var index = start
        while index + markerChars.count <= chars.count {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "`" {
                // Не искать закрытие внутри кода.
                if let close = chars[(index + 1)...].firstIndex(of: "`") { index = close + 1; continue }
            }
            if Array(chars[index..<(index + markerChars.count)]) == markerChars { return index }
            index += 1
        }
        return nil
    }

    private static func isWordBoundary(_ chars: [Character], _ index: Int) -> Bool {
        guard index >= 0, index < chars.count else { return true }
        return !(chars[index].isLetter || chars[index].isNumber)
    }
}
