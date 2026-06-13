import Foundation
import AVFoundation
import Combine

/// Audio stream player using AVPlayer for AAC/HLS streams
@MainActor
final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentStation: RadioStation?

    /// Reachability status per station ID: true = reachable, false = unreachable, nil = unchecked
    @Published var reachability: [String: Bool?] = [:]

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var reachabilityTask: Task<Void, Never>?

    private static let lastStationKey = "island-radio-last-station-id"

    /// The ID of the last played station (persisted in UserDefaults).
    var lastStationId: String? {
        get { UserDefaults.standard.string(forKey: Self.lastStationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastStationKey) }
    }

    func play(station: RadioStation) {
        stop()

        currentStation = station
        lastStationId = station.id
        appLog("[AudioPlayer] Playing: \(station.name) — \(station.url)")

        guard let url = URL(string: station.url) else {
            appLog("[AudioPlayer] Invalid URL: \(station.url)")
            return
        }

        // For m3u8/HLS streams, try to find audio-only variant to save bandwidth
        if station.url.hasSuffix(".m3u8") || station.url.contains(".m3u8?") {
            Task {
                if let audioUrl = await Self.resolveAudioOnlyURL(from: url) {
                    appLog("[AudioPlayer] Found audio-only variant: \(audioUrl)")
                    await MainActor.run { self.startPlayback(url: audioUrl, station: station) }
                } else {
                    appLog("[AudioPlayer] No audio-only variant found, using original URL")
                    await MainActor.run { self.startPlayback(url: url, station: station) }
                }
            }
        } else {
            startPlayback(url: url, station: station)
        }
    }

    private func startPlayback(url: URL, station: RadioStation) {
        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // For m3u8 video streams, disable video tracks (fallback if no audio-only variant)
        selectAudioOnlyTracks(for: playerItem)

        // Observe player status
        statusObserver = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                switch item.status {
                case .readyToPlay:
                    appLog("[AudioPlayer] Ready to play: \(station.name)")
                    self?.selectAudioOnlyTracks(for: item)
                case .failed:
                    appLog("[AudioPlayer] Failed: \(item.error?.localizedDescription ?? "unknown")")
                    self?.isPlaying = false
                default:
                    break
                }
            }
        }

        // Observe rate changes to track actual play state
        rateObserver = player?.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.rate > 0
            }
        }

        // Observe for errors
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { notification in
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                appLog("[AudioPlayer] Playback error: \(error.localizedDescription)")
            }
        }

        player?.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        statusObserver?.invalidate()
        rateObserver?.invalidate()
        statusObserver = nil
        rateObserver = nil
        player = nil
        playerItem = nil
        isPlaying = false
    }

    /// Pause without destroying the player (for word lookup).
    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Resume after pause.
    func resume() {
        guard player != nil else { return }
        player?.play()
        isPlaying = true
    }

    func toggle(station: RadioStation) {
        if isPlaying && currentStation == station {
            stop()
        } else {
            play(station: station)
        }
    }

    /// Set system audio output volume (0.0 - 1.0)
    var volume: Float {
        get { player?.volume ?? 1.0 }
        set { player?.volume = newValue }
    }

    /// For m3u8/HLS video streams, disable video tracks and select only audio.
    /// This ensures m3u8 video streams play as audio-only without video rendering.
    private func selectAudioOnlyTracks(for item: AVPlayerItem?) {
        guard let item = item else { return }
        let asset = item.asset

        // Access tracks via the player item's track group (available after loading)
        let playerItemTracks = item.tracks
        guard !playerItemTracks.isEmpty else { return }

        for track in playerItemTracks {
            if let group = track.assetTrack?.mediaType {
                if group == .video {
                    // Disable video tracks
                    track.isEnabled = false
                    appLog("[AudioPlayer] Disabled video track in HLS stream")
                } else if group == .audio {
                    // Ensure audio tracks are enabled
                    track.isEnabled = true
                }
            }
        }
    }

    // MARK: - HLS Audio-Only Resolution

    /// Parse an HLS master playlist to find an audio-only variant stream URL.
    /// Returns nil if no audio-only variant is found (or if the URL is not a valid m3u8).
    private static func resolveAudioOnlyURL(from url: URL) async -> URL? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let playlist = String(data: data, encoding: .utf8) else {
                return nil
            }

            // Check if this is a master playlist (contains #EXT-X-STREAM-INF)
            guard playlist.contains("#EXT-X-STREAM-INF") else {
                // This is already a media playlist, not a master playlist
                return nil
            }

            let lines = playlist.components(separatedBy: .newlines)
            var audioOnlyURL: URL?
            var lowestBitrateURL: URL?
            var lowestBitrate: Int = Int.max

            for i in 0..<lines.count {
                let line = lines[i]
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    // Parse BANDWIDTH and CODECS from the stream info line
                    let bandwidth = parseAttributeValue(in: line, key: "BANDWIDTH").flatMap { Int($0) } ?? 0
                    let codecs = parseAttributeValue(in: line, key: "CODECS") ?? ""

                    // Next non-empty, non-comment line is the variant URL
                    let variantURL = findNextURL(lines: lines, after: i, baseURL: url)

                    // Check if this variant is audio-only (no video codec in CODECS)
                    if isAudioOnlyCodec(codecs: codecs), let vURL = variantURL {
                        appLog("[AudioPlayer] Found audio-only variant: bandwidth=\(bandwidth), codecs=\(codecs)")
                        // Prefer the first (usually lowest bandwidth) audio-only variant
                        if audioOnlyURL == nil {
                            audioOnlyURL = vURL
                        }
                    }

                    // Track lowest bandwidth variant as fallback
                    if bandwidth < lowestBitrate, let vURL = variantURL {
                        lowestBitrate = bandwidth
                        lowestBitrateURL = vURL
                    }
                }
            }

            // Prefer audio-only, otherwise use lowest bandwidth variant
            return audioOnlyURL ?? lowestBitrateURL
        } catch {
            appLog("[AudioPlayer] Failed to resolve audio-only URL: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse a quoted attribute value from an HLS tag line, e.g. CODECS="avc1.640029,mp4a.40.2"
    private static func parseAttributeValue(in line: String, key: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            // Quoted value
            let afterQuote = rest.index(after: rest.startIndex)
            if let endQuote = rest[afterQuote...].firstIndex(of: "\"") {
                return String(rest[afterQuote..<endQuote])
            }
        }
        // Unquoted: read until comma or end
        let restStr = String(rest)
        if let commaIdx = restStr.firstIndex(of: ",") {
            return String(restStr[..<commaIdx])
        }
        return String(rest)
    }

    /// Find the next non-empty, non-comment line after line index as a variant URL.
    private static func findNextURL(lines: [String], after index: Int, baseURL: URL) -> URL? {
        for i in (index + 1)..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Resolve relative URL against base
            if let resolved = URL(string: line, relativeTo: baseURL) {
                return resolved
            }
            if let absolute = URL(string: line) {
                return absolute
            }
            break
        }
        return nil
    }

    /// Check if CODECS string indicates audio-only (no video codec).
    /// Common video codecs: avc1, av01, hev1, hvc1, vp09
    /// Audio-only: just mp4a, ac-3, ec-3, aac, etc.
    private static func isAudioOnlyCodec(codecs: String) -> Bool {
        let videoCodecPrefixes = ["avc1", "avc3", "hev1", "hvc1", "av01", "vp09", "vp8", "vp9"]
        let codecList = codecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return !codecList.contains { codec in
            videoCodecPrefixes.contains { codec.hasPrefix($0) }
        }
    }

    // MARK: - Reachability Check

    /// Check reachability for all given stations (lightweight HEAD request).
    func checkReachability(for stations: [RadioStation]) {
        // Cancel previous batch
        reachabilityTask?.cancel()
        reachabilityTask = Task {
            // Mark all as nil (checking) first
            for station in stations {
                reachability[station.id] = nil
            }
            // Check concurrently with a limit
            await withTaskGroup(of: (String, Bool).self) { group in
                for station in stations {
                    group.addTask {
                        let reachable = await Self.isURLReachable(station.url)
                        return (station.id, reachable)
                    }
                }
                for await (id, reachable) in group {
                    guard !Task.isCancelled else { return }
                    self.reachability[id] = reachable
                }
            }
        }
    }

    /// Lightweight reachability check using a HEAD request with short timeout.
    private static func isURLReachable(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        // For m3u8, HEAD may not work; also try GET with limited data
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode < 400 {
                return true
            }
            // Some servers reject HEAD, try GET
            var getRequest = URLRequest(url: url)
            getRequest.timeoutInterval = 5
            let (_, getResponse) = try await URLSession.shared.data(for: getRequest)
            if let httpResponse = getResponse as? HTTPURLResponse,
               httpResponse.statusCode < 400 {
                return true
            }
            return false
        } catch {
            // Timeout or connection refused
            return false
        }
    }
}
