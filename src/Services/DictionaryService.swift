import Foundation

/// System dictionary service using macOS DictionaryServices framework.
/// Works as an alternative to LLM-based lookup — zero dependencies, offline, instant.
/// Returns Chinese definitions (英汉) when available, falls back to English.
enum DictionaryService {

    // MARK: - Public API

    /// Look up a word in the system dictionaries.
    static func lookup(_ word: String, sentence: String) async -> TranslationResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        appLog("[Dict] lookup: '\(word)'")

        ensureLoaded()

        // Try DCSCopyDefinitionMarkup first — returns CFData (HTML), safe to handle
        if let fn = _dcsCopyMarkup, let data = fn(word as CFString) {
            if let html = decodeCFData(data) {
                appLog("[Dict] markup: \(html.count) chars")
                let result = parseHTML(html)
                if result.meaning != nil {
                    appLog("[Dict] done: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
                    return result
                }
            }
        }

        // Fallback: DCSSearch — also returns CFData (HTML)
        if let fn = _dcsSearch, let data = fn(word as CFString) {
            if let html = decodeCFData(data) {
                appLog("[Dict] search: \(html.count) chars")
                let result = parseHTML(html)
                if result.meaning != nil {
                    appLog("[Dict] done: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
                    return result
                }
            }
        }

        appLog("[Dict] no results for '\(word)'")
        return TranslationResult(meaning: "未找到释义")
    }

    // MARK: - DictionaryServices bindings

    private static var dictLibLoaded = false
    // DCSCopyDefinitionMarkup(CFStringRef) -> CFDataRef?
    private static var _dcsCopyMarkup: ((CFString) -> Unmanaged<CFData>?)?
    // DCSSearch(CFStringRef) -> CFDataRef?
    private static var _dcsSearch: ((CFString) -> Unmanaged<CFData>?)?

    private static func ensureLoaded() {
        guard !dictLibLoaded else { return }
        dictLibLoaded = true

        guard let bundleURL = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault,
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/DictionaryServices.framework" as CFString,
            .cfurlposixPathStyle,
            true
        ),
        let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL) else {
            appLog("[Dict] Failed to create bundle")
            return
        }

        // DCSCopyDefinitionMarkup(CFStringRef) -> CFDataRef?
        if let sym = CFBundleGetFunctionPointerForName(bundle, "DCSCopyDefinitionMarkup" as CFString) {
            typealias Fn = @convention(c) (CFString) -> Unmanaged<CFData>?
            let f = unsafeBitCast(sym, to: Fn.self)
            _dcsCopyMarkup = { term in f(term) }
            appLog("[Dict] DCSCopyDefinitionMarkup loaded")
        }

        // DCSSearch(CFStringRef) -> CFDataRef?
        if let sym = CFBundleGetFunctionPointerForName(bundle, "DCSSearch" as CFString) {
            typealias Fn = @convention(c) (CFString) -> Unmanaged<CFData>?
            let f = unsafeBitCast(sym, to: Fn.self)
            _dcsSearch = { term in f(term) }
            appLog("[Dict] DCSSearch loaded")
        }

        appLog("[Dict] ready: markup=\(_dcsCopyMarkup != nil), search=\(_dcsSearch != nil)")
    }

    // MARK: - CFData decoding

    /// Decode CFData to String. Try UTF-16 first (per Apple docs), then UTF-8.
    private static func decodeCFData(_ data: Unmanaged<CFData>) -> String? {
        let cfData = data.takeRetainedValue()
        let len = CFDataGetLength(cfData)
        guard len > 0 else { return nil }

        let swiftData = cfData as Data

        // Try UTF-16 (documented format for DCSSearch/DCSCopyDefinitionMarkup)
        let count = len / MemoryLayout<UInt16>.size
        if count > 0 {
            let str = swiftData.withUnsafeBytes { rawBuf -> String? in
                guard let base = rawBuf.baseAddress else { return nil }
                let ptr = base.assumingMemoryBound(to: UInt16.self)
                return String(utf16CodeUnits: ptr, count: count)
            }
            if let str = str, str.contains("<") { return str }
        }

        // Fallback: UTF-8
        if let str = String(data: swiftData, encoding: .utf8) {
            return str
        }

        // Fallback: ASCII/Latin1
        return String(data: swiftData, encoding: .ascii)
    }

    // MARK: - HTML parsing

    private static func parseHTML(_ html: String) -> TranslationResult {
        let text = stripTags(html).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return TranslationResult(meaning: nil)
        }

        // Extract phonetic: /.../ or [...]
        var phonetic: String?
        if let range = text.range(of: "/[^/]+/", options: .regularExpression) {
            let p = String(text[range])
            if p.count < 40 { phonetic = p }
        }

        // Split into definition lines
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "▸•\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 1 }

        // Separate Chinese vs English lines
        var chineseLines: [String] = []
        var englishLines: [String] = []
        for line in lines {
            if containsChinese(line) {
                chineseLines.append(line)
            } else {
                englishLines.append(line)
            }
        }

        // Prefer Chinese definitions, fallback to English
        let meaning: String?
        if !chineseLines.isEmpty {
            meaning = chineseLines.prefix(5).joined(separator: "\n")
        } else if !englishLines.isEmpty {
            // Skip the first line if it looks like a headword repeat
            let defs = englishLines.count > 1 && englishLines[0].count < 20
                ? Array(englishLines.dropFirst())
                : englishLines
            meaning = defs.prefix(4).joined(separator: "\n")
        } else {
            meaning = nil
        }

        return TranslationResult(
            phonetic: phonetic,
            meaning: meaning,
            example: nil
        )
    }

    // MARK: - Utilities

    /// Strip HTML tags and decode entities.
    private static func stripTags(_ s: String) -> String {
        var result = s
        while let range = result.range(of: "<[^>]+>", options: .regularExpression) {
            result.removeSubrange(range)
        }
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return result
    }

    /// Check if a string contains Chinese characters.
    private static func containsChinese(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
            (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
        }
    }
}
