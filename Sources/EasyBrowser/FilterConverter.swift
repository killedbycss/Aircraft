import Foundation

/// Переводит списки фильтров в синтаксисе Adblock Plus / uBlock Origin / AdGuard в правила
/// WebKit Content Blocker (`WKContentRuleList`).
///
/// Поддерживается:
/// - сетевые правила: `||домен^`, `|адрес`, `*`, `^`, `@@` (исключения), `/регулярки/`
///   (подмножество, которое понимает WebKit);
/// - параметры `$third-party`/`$1p`, типы ресурсов (`script`, `image`, `xhr`, `subdocument`,
///   `~script`…), `$domain=`/`$from=`, `$match-case`, `$popup`, `$document`, `$badfilter`;
/// - скрытие элементов `##` (общее и для доменов, в том числе `домен.*`) и исключения `#@#`;
/// - hosts-файлы (`0.0.0.0 домен`).
///
/// Процедурные фильтры (`:has-text`, `:upward`…), скриптлеты (`+js`), `$redirect`,
/// `$removeparam`, `$csp` и подобные WebKit выполнить не может — такие строки пропускаются.
enum FilterConverter {
    /// Меняется при изменении логики конвертера, чтобы пересобрать закэшированные правила.
    static let version = 3

    struct Result {
        /// Блокировка запросов.
        var blocks: [[String: Any]] = []
        /// Скрытие элементов.
        var hiding: [[String: Any]] = []
        /// Исключения (`ignore-previous-rules`): их нужно ставить после всех остальных правил.
        var exceptions: [[String: Any]] = []
        /// Блокировка страниц целиком (`$document`) — ставится после `topFrameAllowance`.
        var documentBlocks: [[String: Any]] = []
        var converted = 0
        var skipped = 0

        var ruleCount: Int { blocks.count + hiding.count + exceptions.count + documentBlocks.count }

        mutating func append(_ other: Result) {
            blocks += other.blocks
            hiding += other.hiding
            exceptions += other.exceptions
            documentBlocks += other.documentBlocks
            converted += other.converted
            skipped += other.skipped
        }
    }

    /// Как в Adblock Plus: сетевые правила не блокируют саму открываемую страницу (иначе
    /// ломаются переходы по ссылкам через счётчики). Ставится после блокировок и до скрытия
    /// элементов — иначе отменило бы и скрытие на этой странице.
    static var topFrameAllowance: [String: Any] { [
        "trigger": ["url-filter": ".*", "resource-type": ["document"], "load-context": ["top-frame"]],
        "action": ["type": "ignore-previous-rules"]
    ] }

    // MARK: - Публичный интерфейс

    static func convert(_ text: String) -> Result {
        var result = Result()
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Первый проход: $badfilter и исключения для скрытия элементов.
        var badFilters = Set<String>()
        var hideExceptions: [String: [String]] = [:]   // селектор → домены-исключения
        var globallyAllowedSelectors = Set<String>()
        for line in lines where !isComment(line) {
            if let range = line.range(of: "$badfilter") ?? line.range(of: ",badfilter") {
                badFilters.insert(line.replacingCharacters(in: range, with: "").replacingOccurrences(of: "$,", with: "$"))
            }
            if let cosmetic = splitCosmetic(line), cosmetic.separator == "#@#" {
                let domains = parseDomains(cosmetic.domains).positive
                if domains.isEmpty { globallyAllowedSelectors.insert(cosmetic.body) }
                else { hideExceptions[cosmetic.body, default: []] += domains }
            }
        }

        var genericSelectors: [String] = []
        var domainSelectors: [String: (ifDomain: [String]?, unlessDomain: [String]?, selectors: [String])] = [:]

        for line in lines {
            if isComment(line) || line.contains("badfilter") || badFilters.contains(line) { continue }

            if let cosmetic = splitCosmetic(line) {
                guard cosmetic.separator == "##" else {
                    if cosmetic.separator != "#@#" { result.skipped += 1 }
                    continue
                }
                let selector = cosmetic.body
                guard isSupportedSelector(selector), !globallyAllowedSelectors.contains(selector) else {
                    result.skipped += 1
                    continue
                }
                let domains = parseDomains(cosmetic.domains)
                if cosmetic.domains.isEmpty {
                    if let exceptions = hideExceptions[selector] {
                        // У общего селектора есть исключения — отдельное правило с unless-domain.
                        result.hiding.append(cssRule(selector, ifDomain: nil, unlessDomain: exceptions.map { "*" + $0 }))
                    } else {
                        genericSelectors.append(selector)
                    }
                } else if domains.invalid {
                    result.skipped += 1
                    continue
                } else if !domains.positive.isEmpty {
                    let key = "+" + domains.positive.joined(separator: ",")
                    domainSelectors[key, default: (domains.positive.map { "*" + $0 }, nil, [])].selectors.append(selector)
                } else {
                    let key = "-" + domains.negative.joined(separator: ",")
                    domainSelectors[key, default: (nil, domains.negative.map { "*" + $0 }, [])].selectors.append(selector)
                }
                result.converted += 1
                continue
            }

            if let hostsRule = hostsLine(line) {
                appendNetwork(hostsRule, into: &result)
                continue
            }
            appendNetwork(line, into: &result)
        }

        // Скрытие элементов — по одному селектору на правило: WebKit отбрасывает неверный
        // селектор, и он не утягивает за собой соседей.
        for selector in genericSelectors {
            result.hiding.append(cssRule(selector, ifDomain: nil, unlessDomain: nil))
        }
        for key in domainSelectors.keys.sorted() {
            let group = domainSelectors[key]!
            for selector in group.selectors {
                result.hiding.append(cssRule(selector, ifDomain: group.ifDomain, unlessDomain: group.unlessDomain))
            }
        }
        return result
    }

    // MARK: - Разбор строк

    private static func isComment(_ line: String) -> Bool {
        line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") && !line.hasPrefix("[$") || line.hasPrefix("# ") || line == "#"
    }

    private struct Cosmetic {
        let domains: String
        let separator: String
        let body: String
    }

    private static let cosmeticSeparators = ["#@$?#", "#$?#", "#@?#", "#@$#", "#@%#", "#?#", "#$#", "#%#", "#@#", "##"]

    private static func splitCosmetic(_ line: String) -> Cosmetic? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let tail = line[hash...]
        for separator in cosmeticSeparators where tail.hasPrefix(separator) {
            let domains = String(line[..<hash])
            // «||example.com/#ad» — сетевое правило с якорем в адресе, а не косметика.
            if domains.contains("/") && !domains.hasPrefix("[$") { return nil }
            return Cosmetic(domains: domains, separator: separator, body: String(tail.dropFirst(separator.count)))
        }
        return nil
    }

    /// Псевдоклассы, которых нет в CSS: такие фильтры понимают только расширения.
    private static let proceduralMarkers = [
        ":has-text(", ":-abp-", ":contains(", ":upward(", ":xpath(", ":matches-css", ":style(", ":remove(",
        ":matches-path(", ":matches-attr(", ":matches-prop(", ":min-text-length(", ":watch-attr(", ":others(",
        ":if(", ":if-not(", ":nth-ancestor(", ":remove-attr(", ":remove-class(", ":shadow(", "+js(", "^script"
    ]

    private static func isSupportedSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, !selector.hasPrefix("+js"), !selector.hasPrefix("^"),
              selector.allSatisfy({ $0.isASCII || $0.isLetter }) else { return false }
        return !proceduralMarkers.contains { selector.contains($0) }
    }

    /// Доменные зоны для правил вида `yandex.*##…` (WebKit не понимает «*» в домене).
    private static let wildcardTLDs = ["com", "ru", "net", "org", "by", "kz", "ua", "uz", "de", "fr", "es", "it",
                                       "pl", "co.uk", "com.tr", "com.br", "ca", "nl", "in", "io", "me", "tv", "cc", "to"]

    private struct Domains {
        var positive: [String] = []
        var negative: [String] = []
        /// Были домены, но ни один не удалось перевести — правило нельзя делать общим.
        var invalid = false
    }

    private static func parseDomains(_ raw: String, separator: Character = ",") -> Domains {
        var domains = Domains()
        if raw.hasPrefix("[$") { domains.invalid = true; return domains }
        var sawAny = false
        for part in raw.split(separator: separator) {
            var item = part.trimmingCharacters(in: .whitespaces).lowercased()
            guard !item.isEmpty else { continue }
            sawAny = true
            let negated = item.hasPrefix("~")
            if negated { item.removeFirst() }
            var expanded: [String]
            if item.hasSuffix(".*") {
                let base = String(item.dropLast(2))
                expanded = wildcardTLDs.map { "\(base).\($0)" }
            } else {
                expanded = [item]
            }
            expanded = expanded.filter { isPlainDomain($0) }
            if negated { domains.negative += expanded } else { domains.positive += expanded }
        }
        if sawAny && domains.positive.isEmpty && domains.negative.isEmpty { domains.invalid = true }
        return domains
    }

    private static func isPlainDomain(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    private static func hostsLine(_ line: String) -> String? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, ["0.0.0.0", "127.0.0.1", "::"].contains(String(parts[0])) else { return nil }
        let host = String(parts[1]).lowercased()
        guard isPlainDomain(host), host.contains("."), host != "localhost" else { return "" }
        return "||\(host)^"
    }

    // MARK: - Сетевые правила

    private static let typeMap: [String: [String]] = [
        "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "xmlhttprequest": ["raw", "fetch"], "xhr": ["raw", "fetch"], "subdocument": ["document"], "frame": ["document"],
        "media": ["media"], "font": ["font"], "websocket": ["websocket"], "ping": ["ping"], "beacon": ["ping"],
        "other": ["other"], "object": ["other"], "popup": ["popup"], "document": ["document"], "doc": ["document"]
    ]
    private static let allTypes = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document",
                                   "media", "popup", "ping", "fetch", "websocket", "other"]
    private static let ignoredOptions: Set<String> = ["important", "match-case", "all", "~match-case", "stealth", "strict1p", "strict3p"]

    private static func appendNetwork(_ line: String, into result: inout Result) {
        guard !line.isEmpty else { return }
        var text = line
        let isException = text.hasPrefix("@@")
        if isException { text.removeFirst(2) }

        // Параметры после последнего «$» (если это не часть регулярного выражения).
        var options: [String] = []
        if let dollar = text.lastIndex(of: "$") {
            let tail = text[text.index(after: dollar)...]
            let isRegexEnd = text.hasPrefix("/") && tail.contains("/")
            if !isRegexEnd, !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0 != " " }) {
                options = tail.split(separator: ",").map { String($0).lowercased() }
                text = String(text[..<dollar])
            }
        }

        var trigger: [String: Any] = [:]
        var types: Set<String>? = nil
        var negatedTypes = Set<String>()
        var isDocumentException = false
        var blocksDocument = false

        for option in options {
            let name = option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? option
            let value = option.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
            switch name {
            case "third-party", "3p", "~first-party", "~1p":
                trigger["load-type"] = ["third-party"]
            case "~third-party", "~3p", "first-party", "1p":
                trigger["load-type"] = ["first-party"]
            case "domain", "from":
                guard let value else { result.skipped += 1; return }
                let domains = parseDomains(value, separator: "|")
                if domains.invalid { result.skipped += 1; return }
                if !domains.positive.isEmpty { trigger["if-domain"] = domains.positive.map { "*" + $0 } }
                else if !domains.negative.isEmpty { trigger["unless-domain"] = domains.negative.map { "*" + $0 } }
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            default:
                if ignoredOptions.contains(name) { continue }
                let negated = name.hasPrefix("~")
                let typeName = negated ? String(name.dropFirst()) : name
                guard let mapped = typeMap[typeName] else {
                    // $redirect, $removeparam, $csp, $generichide… WebKit их не умеет.
                    result.skipped += 1
                    return
                }
                if negated {
                    negatedTypes.formUnion(mapped)
                } else {
                    types = (types ?? []).union(mapped)
                    if typeName == "document" || typeName == "doc" {
                        if isException { isDocumentException = true } else { blocksDocument = true }
                    }
                }
            }
        }

        // @@||site.com^$document — отключить блокировку на страницах сайта.
        if isDocumentException {
            guard let host = plainHost(of: text) else { result.skipped += 1; return }
            result.exceptions.append([
                "trigger": ["url-filter": ".*", "if-domain": ["*" + host]],
                "action": ["type": "ignore-previous-rules"]
            ])
            result.converted += 1
            return
        }

        guard let filter = urlFilter(for: text) else { result.skipped += 1; return }
        // Слишком общее правило без ограничений заблокировало бы всё подряд.
        if filter == ".*" && trigger["if-domain"] == nil && types == nil && !isException {
            result.skipped += 1
            return
        }
        trigger["url-filter"] = filter

        if let explicit = types {
            let resolved = explicit.subtracting(negatedTypes)
            guard !resolved.isEmpty else { result.skipped += 1; return }
            trigger["resource-type"] = resolved.sorted()
        } else if !negatedTypes.isEmpty {
            trigger["resource-type"] = Set(allTypes).subtracting(negatedTypes).sorted()
        }
        let rule: [String: Any] = ["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]]
        if isException { result.exceptions.append(rule) }
        else if blocksDocument { result.documentBlocks.append(rule) }
        else { result.blocks.append(rule) }
        result.converted += 1
    }

    /// Хост из правила вида `||example.com^`.
    private static func plainHost(of pattern: String) -> String? {
        var host = pattern
        guard host.hasPrefix("||") else { return nil }
        host.removeFirst(2)
        if host.hasSuffix("^") || host.hasSuffix("/") { host.removeLast() }
        host = host.lowercased()
        return isPlainDomain(host) ? host : nil
    }

    /// Шаблон Adblock → регулярное выражение из подмножества, которое компилирует WebKit
    /// (без `|`, `{}`, `\d`, `(?…)` и не-ASCII символов).
    static func urlFilter(for pattern: String) -> String? {
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let regex = String(pattern.dropFirst().dropLast())
            return isWebKitSafeRegex(regex) ? regex : nil
        }
        guard pattern.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        var body = Substring(pattern)
        var out = ""
        if body.hasPrefix("||") {
            out = #"^[^:]+://+([^/:]+\.)?"#
            body = body.dropFirst(2)
        } else if body.hasPrefix("|") {
            out = "^"
            body = body.dropFirst()
        }
        var anchoredEnd = false
        if body.hasSuffix("|") {
            anchoredEnd = true
            body = body.dropLast()
        }
        guard !body.contains("|") else { return nil }
        let chars = Array(body)
        for (index, ch) in chars.enumerated() {
            switch ch {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                // Разделитель: любой символ кроме букв, цифр и «_-.%», либо конец адреса.
                out += index == chars.count - 1 && !anchoredEnd ? "([^a-zA-Z0-9_.%-].*)?$" : "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "$", "{", "}", "(", ")", "[", "]", "\\":
                out += "\\" + String(ch)
            default:
                out.append(ch)
            }
        }
        if anchoredEnd { out += "$" }
        if out.hasPrefix(".*") { out.removeFirst(2) }
        if out.hasSuffix(".*") { out.removeLast(2) }
        return out.isEmpty ? ".*" : out
    }

    private static func isWebKitSafeRegex(_ regex: String) -> Bool {
        guard regex.allSatisfy({ $0.isASCII }), !regex.contains("|"), !regex.contains("{"), !regex.contains("(?") else {
            return false
        }
        // Классы \d, \w, \s, \b и обратные ссылки WebKit не поддерживает.
        let chars = Array(regex)
        var index = 0
        while index < chars.count {
            if chars[index] == "\\" {
                guard index + 1 < chars.count else { return false }
                let next = chars[index + 1]
                if next.isLetter || next.isNumber { return false }
                index += 2
                continue
            }
            if chars[index] == "^" && index != 0 && chars[index - 1] != "[" { return false }
            if chars[index] == "$" && index != chars.count - 1 { return false }
            index += 1
        }
        return true
    }

    private static func cssRule(_ selector: String, ifDomain: [String]?, unlessDomain: [String]?) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": ".*"]
        if let ifDomain { trigger["if-domain"] = ifDomain }
        if let unlessDomain { trigger["unless-domain"] = unlessDomain }
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }
}
