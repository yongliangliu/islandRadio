import Foundation

/// Radio station model — mirrors the Electron version's RadioStation interface
struct RadioStation: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var url: String
    var language: String   // BCP-47: "en-US", "zh-CN", "ja-JP", etc.
    var color: String?     // badge accent color hex

    static let defaultStations: [RadioStation] = [
        RadioStation(
            id: "cna938",
            name: "CNA938",
            url: "http://28323.live.streamtheworld.com/938NOW_PREM.aac",
            language: "en-US",
            color: "#4ade80"
        ),
    ]

    /// Supported language options for STT
    static let supportedLanguages: [(code: String, label: String)] = [
        ("en-US", "English (US)"),
        ("zh-CN", "中文 (简体)"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
    ]
}

/// Subtitle state from STT
struct SubtitleState: Equatable {
    var text: String = ""
    var isFinal: Bool = false

    static let empty = SubtitleState()
}
