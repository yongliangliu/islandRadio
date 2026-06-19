import Foundation

/// LLM provider type
enum LLMProvider: String, Codable, CaseIterable {
    case openai
    case anthropic
}

/// LLM API configuration
struct LLMConfig: Codable, Equatable {
    var provider: LLMProvider
    var endpoint: String
    var apiKey: String
    var model: String

    static let presets: [LLMProvider: LLMConfig] = [
        .openai: LLMConfig(
            provider: .openai,
            endpoint: "https://api.openai.com/v1/chat/completions",
            apiKey: "",
            model: "gpt-4o-mini"
        ),
        .anthropic: LLMConfig(
            provider: .anthropic,
            endpoint: "https://api.anthropic.com/v1/messages",
            apiKey: "",
            model: "claude-sonnet-4-20250514"
        ),
    ]

    private static let storageKey = "island-radio-llm-config"

    static func load() -> LLMConfig {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let config = try? JSONDecoder().decode(LLMConfig.self, from: data) {
            return config
        }
        return presets[.openai]!
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Service for translating words using LLM APIs.
enum LLMService {

    /// Translate a word in context using the configured LLM.
    static func translateWord(
        _ word: String,
        sentence: String,
        config: LLMConfig
    ) async throws -> TranslationResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let prompt = buildPrompt(word: word, sentence: sentence)
        appLog("[Perf] buildPrompt: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")

        let responseText: String
        switch config.provider {
        case .openai:
            responseText = try await callOpenAI(prompt: prompt, config: config, t0: t0)
        case .anthropic:
            responseText = try await callAnthropic(prompt: prompt, config: config, t0: t0)
        }
        appLog("[Perf] API done: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s (\(config.provider.rawValue))")

        let result = parseResponse(responseText)
        appLog("[Perf] parsed: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")

        return result
    }

    // MARK: - Prompt

    private static func buildPrompt(word: String, sentence: String) -> String {
        """
        你是一个英语学习助手。请为以下英语单词提供翻译和解释。不要思考过程，直接输出JSON。

        单词: "\(word)"
        所在句子: "\(sentence)"

        请严格只回复一个JSON对象，不要有任何解释文字或markdown标记（不要用```json包裹）:
        {
          "phonetic": "音标",
          "rootAnalysis": "词根词缀分析（简短）",
          "syllableBreakdown": "自然拼读分解",
          "meaning": "中文释义（结合句子语境，简洁）",
          "example": "一个简短例句",
          "sentenceTranslation": "整句翻译",
          "levels": ["词汇等级，如：基础/中级/高级/GRE"]
        }
        """
    }

    // MARK: - OpenAI-compatible API

    private static func callOpenAI(prompt: String, config: LLMConfig, t0: CFAbsoluteTime) async throws -> String {
        guard !config.apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        var request = URLRequest(url: URL(string: config.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.3,
            "max_tokens": 800,
            "thinking": ["type": "disabled"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        appLog("[Perf] request built: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s (body \(request.httpBody?.count ?? 0) bytes)")

        let sendStart = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await URLSession.shared.data(for: request)
        let recvDone = CFAbsoluteTimeGetCurrent()
        appLog("[Perf] URLSession.data: \(String(format: "%.3f", recvDone - sendStart))s (from tap: \(String(format: "%.3f", recvDone - t0))s, \(data.count) bytes)")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "(non-utf8)"
        appLog("[LLM] OpenAI status=\(httpResponse.statusCode), body=\(responseBody.prefix(500))")

        guard httpResponse.statusCode == 200 else {
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: responseBody)
        }

        // Try to extract content from standard OpenAI response format
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            appLog("[LLM] OpenAI response is not valid JSON")
            throw LLMError.invalidResponse
        }
        appLog("[Perf] JSON parsed: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")

        // Standard path: choices[0].message.content
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any] {

            // 优先取 content 字段
            if let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }

            // 兼容 think 模型（DeepSeek-R1 等）：content 为空时尝试 reasoning_content
            if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
                appLog("[LLM] OpenAI: content 为空，使用 reasoning_content (长度=\(reasoning.count))")
                return reasoning
            }

            // 兼容 Ollama thinking 模型：reasoning 字段
            if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
                appLog("[LLM] OpenAI: content 为空，使用 reasoning (长度=\(reasoning.count))")
                return reasoning
            }
        }

        // Fallback: some providers use different structures
        // Try: output / result / data.choices etc.
        if let output = json["output"] as? String {
            return output
        }
        if let result = json["result"] as? String {
            return result
        }

        appLog("[LLM] OpenAI response keys: \(json.keys.sorted())")
        throw LLMError.invalidResponse
    }

    // MARK: - Anthropic API

    private static func callAnthropic(prompt: String, config: LLMConfig, t0: CFAbsoluteTime) async throws -> String {
        guard !config.apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        var request = URLRequest(url: URL(string: config.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 800,
            "temperature": 0.3,
            "thinking": ["type": "disabled"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        appLog("[Perf] anthropic request built: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")

        let sendStart = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await URLSession.shared.data(for: request)
        let recvDone = CFAbsoluteTimeGetCurrent()
        appLog("[Perf] anthropic URLSession.data: \(String(format: "%.3f", recvDone - sendStart))s (from tap: \(String(format: "%.3f", recvDone - t0))s)")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "(non-utf8)"
        appLog("[LLM] Anthropic status=\(httpResponse.statusCode), body=\(responseBody.prefix(500))")

        guard httpResponse.statusCode == 200 else {
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: responseBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            appLog("[LLM] Anthropic response is not expected format")
            throw LLMError.invalidResponse
        }

        // 支持 thinking 模型：优先找 type === 'text' 的块，跳过 thinking 块
        let textBlock = content.first { ($0["type"] as? String) == "text" }
        // 兼容没有 type 字段的简单格式
        let fallbackBlock = content.first { ($0["text"] as? String) != nil }
        guard let text = (textBlock ?? fallbackBlock)?["text"] as? String else {
            appLog("[LLM] Anthropic no text block found, content types: \(content.compactMap { $0["type"] })")
            throw LLMError.invalidResponse
        }

        return text
    }

    // MARK: - Response parsing

    /// 从 LLM 返回文本中提取 JSON 对象，兼容 think 模型输出（思维链 + JSON 混合）
    private static func extractJSON(from text: String) -> String? {
        // 先去除 markdown 代码块标记
        var trimmed = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 快速路径：直接以 { 开头，尝试直接解析
        if trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8),
               let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return trimmed
            }
        }

        // 慢速路径：从最后一个 } 向前找匹配的 {，提取完整 JSON 对象
        guard let lastCloseUtf16 = trimmed.lastIndex(of: "}") else { return nil }

        let chars = Array(trimmed)
        let lastCloseOffset = chars.count - 1
        var depth = 0
        var openOffset: Int? = nil
        for i in stride(from: lastCloseOffset, through: 0, by: -1) {
            if chars[i] == "}" {
                depth += 1
            } else if chars[i] == "{" {
                depth -= 1
                if depth == 0 {
                    openOffset = i
                    break
                }
            }
        }

        guard let startOffset = openOffset else { return nil }
        let candidate = String(chars[startOffset...lastCloseOffset])

        if let data = candidate.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return candidate
        }

        return nil
    }

    private static func parseResponse(_ text: String) -> TranslationResult {
        appLog("[LLM] parseResponse 原始文本: \(text.prefix(300))")

        // 去除 markdown 代码块并提取 JSON
        guard let jsonString = extractJSON(from: text) else {
            appLog("[LLM] 无法从响应中提取 JSON: \(text.prefix(200))")
            return TranslationResult(meaning: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            appLog("[LLM] Failed to parse JSON: \(jsonString.prefix(200))")
            return TranslationResult(meaning: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return TranslationResult(
            phonetic: json["phonetic"] as? String,
            rootAnalysis: json["rootAnalysis"] as? String,
            syllableBreakdown: json["syllableBreakdown"] as? String,
            meaning: json["meaning"] as? String,
            example: json["example"] as? String,
            sentenceTranslation: json["sentenceTranslation"] as? String,
            levels: json["levels"] as? [String]
        )
    }
}

enum LLMError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "请先配置 API Key"
        case .invalidResponse:
            return "API 返回格式异常"
        case .apiError(let code, let msg):
            return "API 错误 (\(code)): \(msg.prefix(200))"
        }
    }
}
