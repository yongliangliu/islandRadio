import Foundation

/// Configuration for the remote word-list backend (Cloudflare Workers + D1 KV store).
///
/// 生词本云端同步配置。若 `isValid` 为 true（填写了服务地址与 Token），
/// WordStore 会把远端作为生词本的主数据源；否则仅使用本地 UserDefaults。
struct WordSyncConfig: Codable, Equatable {
    /// API base URL, e.g. https://kvdata.liuyongliang123.workers.dev
    var baseURL: String
    /// Bearer token for authentication.
    var token: String
    /// Logical table / namespace for the word list.
    var table: String

    /// Out-of-the-box default: no remote configured — local-only mode.
    /// 服务地址不预填任何站点，避免分发后默认指向开发者个人后端。
    static let `default` = WordSyncConfig(
        baseURL: "",
        token: "",
        table: "st_words"
    )

    /// Remote sync is enabled only when both base URL and token are provided.
    var isValid: Bool {
        !trimmedBaseURL.isEmpty && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !trimmedTable.isEmpty
    }

    var trimmedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var trimmedTable: String {
        table.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let storageKey = "island-radio-word-sync-config"

    static func load() -> WordSyncConfig {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let config = try? JSONDecoder().decode(WordSyncConfig.self, from: data) {
            return config
        }
        return .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Network layer for syncing the learning word list with the remote KV API.
///
/// API 形态（详见 /health 自描述）：
/// - GET    /api/{table}          列出记录（limit ≤ 200, offset 分页）
/// - POST   /api/{table}          新增或更新（body: {key, value}）
/// - DELETE /api/{table}/{key}    删除
enum RemoteWordSyncService {

    private static let pageLimit = 200

    // MARK: - Public API

    /// Fetch all learning items from the remote table (handles pagination).
    static func fetchAll(config: WordSyncConfig) async throws -> [LearningItem] {
        guard config.isValid else { throw WordSyncError.notConfigured }

        var results: [LearningItem] = []
        var offset = 0

        while true {
            let page = try await fetchPage(config: config, offset: offset)
            results.append(contentsOf: page)
            if page.count < pageLimit { break }
            offset += pageLimit
            // Safety cap to avoid infinite loops
            if offset > 20_000 { break }
        }
        return results
    }

    /// Insert or update a single item (upsert by word key).
    static func upsert(_ item: LearningItem, config: WordSyncConfig) async throws {
        guard config.isValid else { throw WordSyncError.notConfigured }

        let url = try makeURL(config: config, path: "/api/\(config.trimmedTable)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let body = UpsertBody(key: remoteKey(for: item.word), value: item)
        request.httpBody = try JSONEncoder().encode(body)

        try await send(request)
    }

    /// Delete a single item by its word.
    static func delete(word: String, config: WordSyncConfig) async throws {
        guard config.isValid else { throw WordSyncError.notConfigured }

        let key = remoteKey(for: word)
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let url = try makeURL(config: config, path: "/api/\(config.trimmedTable)/\(encodedKey)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        // 404 (already gone) is acceptable for deletion.
        try await send(request, acceptableExtraStatus: [404])
    }

    /// Test the connection: returns the number of items currently stored remotely.
    static func test(config: WordSyncConfig) async throws -> Int {
        let items = try await fetchAll(config: config)
        return items.count
    }

    // MARK: - Helpers

    private static func fetchPage(config: WordSyncConfig, offset: Int) async throws -> [LearningItem] {
        let url = try makeURL(
            config: config,
            path: "/api/\(config.trimmedTable)",
            query: [
                URLQueryItem(name: "limit", value: String(pageLimit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let data = try await send(request)

        // 表首次访问时可能不存在 → 返回空
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WordSyncError.invalidResponse
        }
        guard let rows = json["items"] as? [[String: Any]] else {
            return []
        }

        var items: [LearningItem] = []
        for row in rows {
            guard let value = row["value"] as? [String: Any] else { continue }
            // 宽容解码：云端可能存在其他工具/旧版本写入的缺字段数据，
            // 只要有 word 就接受，缺失字段用默认值补齐。
            if let item = makeItem(fromValue: value, createdAt: row["created_at"] as? String) {
                items.append(item)
            }
        }
        return items
    }

    /// Server timestamp format, e.g. "2026-07-26 04:58:27" (UTC).
    private static let serverDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Leniently map a remote value dict to a LearningItem, tolerating missing fields.
    private static func makeItem(fromValue value: [String: Any], createdAt: String?) -> LearningItem? {
        guard let word = value["word"] as? String,
              !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // timestamp 优先用存储值（Date 默认编码 = 参考日期秒数），
        // 缺失时回退到服务端 created_at，再缺失用当前时间。
        let timestamp: Date
        if let t = value["timestamp"] as? Double {
            timestamp = Date(timeIntervalSinceReferenceDate: t)
        } else if let s = createdAt, let d = serverDateFormatter.date(from: s) {
            timestamp = d
        } else {
            timestamp = Date()
        }

        return LearningItem(
            // id 统一为小写单词（与云端 key 一致），天然去重
            id: remoteKey(for: word),
            word: word,
            phonetic: value["phonetic"] as? String,
            rootAnalysis: value["rootAnalysis"] as? String,
            syllableBreakdown: value["syllableBreakdown"] as? String,
            meaning: value["meaning"] as? String,
            example: value["example"] as? String,
            sentence: value["sentence"] as? String ?? "",
            sentenceTranslation: value["sentenceTranslation"] as? String,
            stationName: value["stationName"] as? String ?? "Unknown",
            timestamp: timestamp,
            mastered: value["mastered"] as? Bool ?? false,
            levels: value["levels"] as? [String],
            updatedAt: (value["updatedAt"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }

    /// Remote key for a word — normalized lowercase, matching WordStore's dedup rule.
    private static func remoteKey(for word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeURL(config: WordSyncConfig, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: config.trimmedBaseURL + path) else {
            throw WordSyncError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw WordSyncError.invalidURL }
        return url
    }

    @discardableResult
    private static func send(_ request: URLRequest, acceptableExtraStatus: Set<Int> = []) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WordSyncError.invalidResponse
        }
        if http.statusCode == 200 || http.statusCode == 201 || acceptableExtraStatus.contains(http.statusCode) {
            return data
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        appLog("[WordSync] HTTP \(http.statusCode): \(body.prefix(200))")
        throw WordSyncError.apiError(statusCode: http.statusCode, message: body)
    }

    private struct UpsertBody: Encodable {
        let key: String
        let value: LearningItem
    }
}

enum WordSyncError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "未配置云端同步服务"
        case .invalidURL:
            return "服务地址无效"
        case .invalidResponse:
            return "服务返回格式异常"
        case .apiError(let code, let msg):
            return "同步失败 (\(code)): \(msg.prefix(160))"
        }
    }
}
