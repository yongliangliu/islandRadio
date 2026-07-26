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
    /// Last local modification time — used for two-way sync conflict resolution (newer wins).
    var updatedAt: Date?

    /// Effective modification time (falls back to creation timestamp for legacy data).
    var lastModified: Date { updatedAt ?? timestamp }
}

/// Manages the learning word list with UserDefaults persistence.
@MainActor
final class WordStore: ObservableObject {
    @Published var items: [LearningItem] = []

    /// Whether a remote sync operation is in progress.
    @Published private(set) var isSyncing = false
    /// Last sync error message (nil when healthy).
    @Published private(set) var syncError: String?

    /// Set of lowercase words for quick lookup (used for subtitle highlighting).
    var learnedWordsSet: Set<String> {
        Set(items.map { $0.word.lowercased() })
    }

    private static let storageKey = "island-radio-learning-list"
    private static let cacheKey = "island-radio-translation-cache"
    private static let maxCacheSize = 3000
    private static let pendingDeletionsKey = "island-radio-pending-deletions"

    /// 已在本地删除、但尚未成功同步到云端的词（小写 key）。
    /// 刷新时先重放删除，并在合并时跳过这些词，避免离线删除的词“复活”。
    private var pendingDeletions: Set<String> = []

    /// 归一化单词 key：小写 + 去首尾空白。也作为 LearningItem.id 与云端 key。
    nonisolated static func wordKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Remote backend configuration. When valid, the remote store is the source of truth.
    private(set) var syncConfig = WordSyncConfig.load()

    /// Whether the remote backend is configured and should be used.
    var isRemoteEnabled: Bool { syncConfig.isValid }

    init() {
        load()
        sanitizeItems()
        normalizeIDs()
        pendingDeletions = Set(UserDefaults.standard.stringArray(forKey: Self.pendingDeletionsKey) ?? [])
        if syncConfig.isValid {
            Task { await refreshFromRemote() }
        }
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
            existing.updatedAt = Date()
            items[idx] = existing
        } else {
            var newItem = item
            newItem.id = Self.wordKey(item.word)
            newItem.updatedAt = Date()
            items.insert(newItem, at: 0)
        }
        // 重新添加时撤销待删除记录
        if pendingDeletions.remove(Self.wordKey(item.word)) != nil {
            savePendingDeletions()
        }
        save()
        // Push the resulting (deduped/merged) item to the remote backend.
        if let idx = items.firstIndex(where: { $0.word.caseInsensitiveCompare(item.word) == .orderedSame }) {
            pushUpsert(items[idx])
        }
    }

    func remove(id: String) {
        let removed = items.first { $0.id == id }
        items.removeAll { $0.id == id }
        save()
        if let word = removed?.word {
            if syncConfig.isValid {
                // 先记账，云端删除成功后再销账；失败则留待下次同步重放
                pendingDeletions.insert(Self.wordKey(word))
                savePendingDeletions()
            }
            pushDelete(word: word)
        }
    }

    func toggleMastered(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].mastered.toggle()
            items[idx].updatedAt = Date()
            save()
            pushUpsert(items[idx])
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

    /// 将历史数据的 UUID id 迁移为单词 key（小写单词），并去重。
    private func normalizeIDs() {
        var changed = false
        var seen = Set<String>()
        var result: [LearningItem] = []
        for var item in items {
            let key = Self.wordKey(item.word)
            if item.id != key {
                item.id = key
                changed = true
            }
            // 同一单词只保留第一条（items 按新→旧排列）
            if seen.contains(key) {
                changed = true
                continue
            }
            seen.insert(key)
            result.append(item)
        }
        if changed {
            items = result
            save()
            appLog("[WordStore] normalized ids to word keys (\(result.count) items)")
        }
    }

    private func savePendingDeletions() {
        UserDefaults.standard.set(Array(pendingDeletions), forKey: Self.pendingDeletionsKey)
    }

    // MARK: - Remote sync

    /// Update the remote backend configuration; persists and refreshes if valid.
    func updateSyncConfig(_ config: WordSyncConfig) {
        let wasValid = syncConfig.isValid
        syncConfig = config
        config.save()
        if config.isValid {
            Task { await refreshFromRemote() }
        } else if wasValid {
            // Switched back to local-only mode.
            syncError = nil
        }
    }

    /// Two-way sync with the remote backend:
    /// - 本地独有的词 → 上传云端
    /// - 云端独有的词 → 并入本地
    /// - 两边都有的词 → 比较最后修改时间，新者胜出；本地较新则回推云端
    func refreshFromRemote() async {
        guard syncConfig.isValid else { return }
        isSyncing = true
        syncError = nil
        let config = syncConfig
        do {
            // 先重放尚未同步成功的删除（离线删除补偿）
            for key in Array(pendingDeletions) {
                do {
                    try await RemoteWordSyncService.delete(word: key, config: config)
                    pendingDeletions.remove(key)
                } catch {
                    appLog("[WordSync] pending delete retry failed for '\(key)': \(error.localizedDescription)")
                }
            }
            savePendingDeletions()

            let remote = try await RemoteWordSyncService.fetchAll(config: config)
            var remoteByWord: [String: LearningItem] = [:]
            for r in remote {
                let key = Self.wordKey(r.word)
                // 仍在待删除清单里的词不并回本地
                guard !pendingDeletions.contains(key) else { continue }
                remoteByWord[key] = r
            }

            var merged: [LearningItem] = []
            var toUpload: [LearningItem] = []

            for local in items {
                let key = Self.wordKey(local.word)
                if let remoteItem = remoteByWord.removeValue(forKey: key) {
                    // 两边都有：最后修改时间新者胜出
                    if local.lastModified > remoteItem.lastModified {
                        merged.append(local)
                        toUpload.append(local)
                    } else {
                        merged.append(remoteItem)
                    }
                } else {
                    // 本地独有 → 上传
                    merged.append(local)
                    toUpload.append(local)
                }
            }
            // 云端独有 → 并入本地
            merged.append(contentsOf: remoteByWord.values)

            for item in toUpload {
                try? await RemoteWordSyncService.upsert(item, config: config)
            }

            merged.sort { $0.timestamp > $1.timestamp }
            items = merged
            save()
            appLog("[WordSync] two-way sync done: \(remote.count) remote, uploaded \(toUpload.count), total \(merged.count)")
        } catch {
            syncError = error.localizedDescription
            appLog("[WordSync] refresh error: \(error.localizedDescription)")
        }
        isSyncing = false
    }

    /// Test connectivity with the given (possibly unsaved) config; returns remote item count.
    func testSyncConnection(_ config: WordSyncConfig) async -> Result<Int, Error> {
        do {
            let count = try await RemoteWordSyncService.test(config: config)
            return .success(count)
        } catch {
            return .failure(error)
        }
    }

    private func pushUpsert(_ item: LearningItem) {
        guard syncConfig.isValid else { return }
        let config = syncConfig
        Task {
            // 与 pushDelete 同样的闪断重试；最终失败也不丢——下次双向同步会把本地较新的词回推
            for (attempt, delay) in [(1, 0.0), (2, 5.0), (3, 15.0)] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                do {
                    try await RemoteWordSyncService.upsert(item, config: config)
                    return
                } catch {
                    appLog("[WordSync] upsert error for '\(item.word)' (attempt \(attempt)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func pushDelete(word: String) {
        guard syncConfig.isValid else { return }
        let config = syncConfig
        let key = Self.wordKey(word)
        Task {
            // 网络闪断容错：失败后 5s/15s 各重试一次，仍失败则留待下次同步重放
            for (attempt, delay) in [(1, 0.0), (2, 5.0), (3, 15.0)] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                do {
                    try await RemoteWordSyncService.delete(word: word, config: config)
                    // 云端删除成功，销账
                    pendingDeletions.remove(key)
                    savePendingDeletions()
                    return
                } catch {
                    appLog("[WordSync] delete error for '\(word)' (attempt \(attempt)): \(error.localizedDescription)")
                }
            }
            appLog("[WordSync] delete for '\(word)' 已记账，下次同步重试")
        }
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
