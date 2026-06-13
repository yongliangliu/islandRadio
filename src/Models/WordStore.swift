import Foundation
import Combine

/// A single word in the learning list, with LLM-provided details.
struct LearningItem: Codable, Identifiable, Equatable {
    var id: String
    var word: String
    var phonetic: String?
    var rootAnalysis: String?
    var syllableBreakdown: String?
    var meaning: String?
    var example: String?
    var sentence: String          // original subtitle sentence
    var sentenceTranslation: String?
    var stationName: String
    var timestamp: Date
    var mastered: Bool
    var levels: [String]?
}

/// Manages the learning word list with UserDefaults persistence.
@MainActor
final class WordStore: ObservableObject {
    @Published var items: [LearningItem] = []

    /// Set of lowercase words for quick lookup (used for subtitle highlighting).
    var learnedWordsSet: Set<String> {
        Set(items.map { $0.word.lowercased() })
    }

    private static let storageKey = "island-radio-learning-list"
    private static let cacheKey = "island-radio-translation-cache"
    private static let maxCacheSize = 3000

    init() {
        load()
        sanitizeItems()
    }

    // MARK: - CRUD

    /// Add a word. Deduplicates by word (case-insensitive).
    /// When an existing entry has dirty data (raw JSON in meaning), always overwrite with new data.
    func add(_ item: LearningItem) {
        if let idx = items.firstIndex(where: { $0.word.caseInsensitiveCompare(item.word) == .orderedSame }) {
            var existing = items[idx]
            let existingMeaningDirty = Self.isDirtyMeaning(existing.meaning)

            // If existing meaning is dirty or empty, always overwrite with new data
            if existingMeaningDirty || existing.meaning == nil || existing.meaning?.isEmpty == true {
                existing.meaning = item.meaning
                existing.phonetic = item.phonetic ?? existing.phonetic
                existing.rootAnalysis = item.rootAnalysis ?? existing.rootAnalysis
                existing.syllableBreakdown = item.syllableBreakdown ?? existing.syllableBreakdown
                existing.example = item.example ?? existing.example
                existing.sentenceTranslation = item.sentenceTranslation ?? existing.sentenceTranslation
                existing.levels = item.levels ?? existing.levels
            } else {
                // Existing is clean — only fill in missing fields
                if existing.phonetic == nil { existing.phonetic = item.phonetic }
                if existing.rootAnalysis == nil { existing.rootAnalysis = item.rootAnalysis }
                if existing.syllableBreakdown == nil { existing.syllableBreakdown = item.syllableBreakdown }
                if existing.example == nil { existing.example = item.example }
                if existing.sentenceTranslation == nil { existing.sentenceTranslation = item.sentenceTranslation }
                if existing.levels == nil { existing.levels = item.levels }
            }
            items[idx] = existing
        } else {
            items.insert(item, at: 0)
        }
        save()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func toggleMastered(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].mastered.toggle()
            save()
        }
    }

    func contains(word: String) -> Bool {
        items.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: - Translation cache

    func cachedTranslation(for word: String, sentence: String) -> TranslationResult? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode([String: TranslationResult].self, from: data) else {
            return nil
        }
        return cache[Self.cacheKeyFor(word: word, sentence: sentence)]
    }

    func cacheTranslation(_ result: TranslationResult, for word: String, sentence: String) {
        var cache: [String: TranslationResult]
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let existing = try? JSONDecoder().decode([String: TranslationResult].self, from: data) {
            cache = existing
        } else {
            cache = [:]
        }

        cache[Self.cacheKeyFor(word: word, sentence: sentence)] = result

        // Evict oldest if over limit
        if cache.count > Self.maxCacheSize {
            let sorted = cache.sorted { $0.key < $1.key }
            cache = Dictionary(uniqueKeysWithValues: Array(sorted.suffix(Self.maxCacheSize)))
        }

        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private static func cacheKeyFor(word: String, sentence: String) -> String {
        "\(word.lowercased())|||\(sentence)"
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let loaded = try? JSONDecoder().decode([LearningItem].self, from: data) else {
            return
        }
        items = loaded
    }

    // MARK: - Data sanitization

    /// Check if a meaning string contains raw JSON / markdown fences (dirty data from failed parsing).
    static func isDirtyMeaning(_ meaning: String?) -> Bool {
        guard let m = meaning, !m.isEmpty else { return false }
        // Contains JSON-like structure or markdown code fence
        return m.contains("```") || (m.contains("{") && m.contains("\"phonetic\""))
    }

    /// Clean up items that have raw JSON stored in meaning (from earlier parsing failures).
    /// Attempts to re-extract the correct meaning from the raw text.
    private func sanitizeItems() {
        var changed = false
        for i in items.indices {
            guard Self.isDirtyMeaning(items[i].meaning) else { continue }

            let raw = items[i].meaning!
            // Try to extract JSON and parse the meaning field
            if let start = raw.firstIndex(of: "{"),
               let end = raw.lastIndex(of: "}"),
               start < end {
                let jsonString = String(raw[start...end])
                if let data = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Successfully parsed — update all fields from JSON
                    if let v = json["meaning"] as? String { items[i].meaning = v }
                    if items[i].phonetic == nil, let v = json["phonetic"] as? String { items[i].phonetic = v }
                    if items[i].rootAnalysis == nil, let v = json["rootAnalysis"] as? String { items[i].rootAnalysis = v }
                    if items[i].syllableBreakdown == nil, let v = json["syllableBreakdown"] as? String { items[i].syllableBreakdown = v }
                    if items[i].example == nil, let v = json["example"] as? String { items[i].example = v }
                    if items[i].sentenceTranslation == nil, let v = json["sentenceTranslation"] as? String { items[i].sentenceTranslation = v }
                    if items[i].levels == nil, let v = json["levels"] as? [String] { items[i].levels = v }
                    changed = true
                    appLog("[WordStore] Sanitized dirty item: \(items[i].word)")
                } else {
                    // JSON parse failed — clear the dirty meaning
                    items[i].meaning = nil
                    changed = true
                    appLog("[WordStore] Cleared unparseable dirty meaning for: \(items[i].word)")
                }
            } else {
                // No JSON found — clear the dirty meaning
                items[i].meaning = nil
                changed = true
                appLog("[WordStore] Cleared dirty meaning (no JSON) for: \(items[i].word)")
            }
        }
        if changed {
            save()
            appLog("[WordStore] Sanitization complete, saved \(items.count) items")
        }
    }
}

/// LLM translation result for a word.
struct TranslationResult: Codable, Equatable {
    var phonetic: String?
    var rootAnalysis: String?
    var syllableBreakdown: String?
    var meaning: String?
    var example: String?
    var sentenceTranslation: String?
    var levels: [String]?
}
