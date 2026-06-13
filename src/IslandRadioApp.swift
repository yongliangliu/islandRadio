import SwiftUI
import AppKit
import Combine
import MediaPlayer

/// App entry point — manages the Island window, main window, and menu bar status item.
@main
struct IslandRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var stationStore = StationStore()
    @StateObject private var audioPlayer = AudioPlayer()
    @StateObject private var sttBridge = STTBridgeServer()
    @StateObject private var wordStore = WordStore()

    var body: some Scene {
        WindowGroup("Island Radio") {
            MainContentView()
                .environmentObject(stationStore)
                .environmentObject(audioPlayer)
                .environmentObject(sttBridge)
                .environmentObject(wordStore)
                .onAppear {
                    appDelegate.setup(
                        stationStore: stationStore,
                        audioPlayer: audioPlayer,
                        sttBridge: sttBridge,
                        wordStore: wordStore
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 420, height: 560)
    }
}

/// AppDelegate handles the Island window lifecycle and menu bar status item
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One IslandWindow per screen, keyed by screen identifier
    private var islandWindows: [String: IslandWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var mediaKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private weak var stationStore: StationStore?
    private weak var audioPlayer: AudioPlayer?
    private weak var sttBridge: STTBridgeServer?
    private weak var wordStore: WordStore?

    /// Whether playback was paused for word lookup (to resume after card dismissed)
    private var pausedForLookup = false

    private var setupDone = false

    func setup(
        stationStore: StationStore,
        audioPlayer: AudioPlayer,
        sttBridge: STTBridgeServer,
        wordStore: WordStore
    ) {
        guard !setupDone else { return }
        setupDone = true

        appLog("[App] setup() called")
        self.stationStore = stationStore
        self.audioPlayer = audioPlayer
        self.sttBridge = sttBridge
        self.wordStore = wordStore

        // Start WebSocket server for Chrome extension
        sttBridge.start()
        appLog("[App] STT Bridge started")

        // Create Island window(s) — one per screen
        createIslandWindows()
        appLog("[App] Island windows created (\(islandWindows.count) screen(s))")

        // Monitor screen changes (connect/disconnect monitors)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        // Check screens after system wake (screens may have changed during sleep)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.handleScreenParametersChanged()
            }
        }

        // Show initial station name (last played or first available)
        let initialStation: RadioStation?
        if let lastId = audioPlayer.lastStationId,
           let last = stationStore.stations.first(where: { $0.id == lastId }) {
            initialStation = last
        } else {
            initialStation = stationStore.stations.first
        }
        if let station = initialStation {
            forEachIslandWindow { $0.updateStation(name: station.name, color: station.color, isPlaying: false) }
        }

        // Observe state changes to update Island
        observeChanges(audioPlayer: audioPlayer, sttBridge: sttBridge)

        // Register media key handlers (keyboard play/pause, next track)
        setupRemoteCommands()

        appLog("[App] Setup complete")
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // Make the app a regular app (not LSUIElement) so it shows in Dock
            NSApp.setActivationPolicy(.regular)
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep running when main window is closed
    }

    // MARK: - Island Window Management

    /// Helper to get a stable key for an NSScreen (using frame-based identifier)
    private func screenKey(for screen: NSScreen) -> String {
        // Use screen's deviceDescription displayID for a truly stable identifier.
        // This survives origin changes when screens are rearranged after lid open/close.
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return "display_\(screenNumber)"
        }
        // Fallback: use size only (origin can change on reconnect)
        return "screen_\(Int(screen.frame.width))_\(Int(screen.frame.height))"
    }

    /// Create one IslandWindow per connected screen
    private func createIslandWindows() {
        for screen in NSScreen.screens {
            let key = screenKey(for: screen)
            guard islandWindows[key] == nil else { continue }
            let window = IslandWindow(screen: screen)
            connectWindowCallbacks(window)
            if let words = wordStore?.learnedWordsSet {
                window.updateLearnedWords(words)
            }
            window.orderFront(nil)
            islandWindows[key] = window
            appLog("[App] Created Island window for screen: \(key)")
        }
    }

    /// Handle screen connect/disconnect
    private func handleScreenParametersChanged() {
        let currentScreens = NSScreen.screens
        let currentKeys = Set(currentScreens.map { screenKey(for: $0) })
        let existingKeys = Set(islandWindows.keys)

        // Remove windows for disconnected screens (displayID no longer present)
        for key in existingKeys.subtracting(currentKeys) {
            islandWindows[key]?.close()
            islandWindows.removeValue(forKey: key)
            appLog("[App] Removed Island window for disconnected screen: \(key)")
        }

        // Remove windows that are not at a valid top-center position on any screen
        // (handles stale windows that macOS moved to wrong screen after sleep/wake)
        for (key, window) in islandWindows {
            let windowTop = window.frame.maxY
            let windowCenterX = window.frame.midX
            let isOnValidScreen = currentScreens.contains { screen in
                let screenTop = screen.frame.maxY
                let screenCenterX = screen.frame.midX
                return abs(windowTop - screenTop) < 5 && abs(windowCenterX - screenCenterX) < window.frame.width
            }
            if !isOnValidScreen {
                window.close()
                islandWindows.removeValue(forKey: key)
                appLog("[App] Removed mispositioned Island window: \(key)")
            }
        }

        // Create windows for newly connected screens, reposition existing ones
        for screen in currentScreens {
            let key = screenKey(for: screen)
            if islandWindows[key] != nil {
                // Screen still exists — just reposition in case frame changed
                islandWindows[key]?.reposition()
            } else {
                // New screen — create window
                let window = IslandWindow(screen: screen)
                connectWindowCallbacks(window)
                if let station = audioPlayer?.currentStation {
                    window.updateStation(name: station.name, color: station.color, isPlaying: audioPlayer?.isPlaying == true)
                } else if let lastId = audioPlayer?.lastStationId,
                          let last = stationStore?.stations.first(where: { $0.id == lastId }) {
                    window.updateStation(name: last.name, color: last.color, isPlaying: false)
                } else if let first = stationStore?.stations.first {
                    window.updateStation(name: first.name, color: first.color, isPlaying: false)
                }
                window.updateRecording(sttBridge?.isListening == true)
                if let subtitle = sttBridge?.subtitle, !subtitle.text.isEmpty {
                    window.updateSubtitle(subtitle)
                }
                if let words = wordStore?.learnedWordsSet {
                    window.updateLearnedWords(words)
                }
                window.orderFront(nil)
                islandWindows[key] = window
                appLog("[App] Created Island window for new screen: \(key)")
            }
        }
    }

    /// Connect button/callback handlers to an IslandWindow
    private func connectWindowCallbacks(_ window: IslandWindow) {
        window.onPlayTapped = { [weak self] in
            self?.handlePlayTapped()
        }
        window.onNextTapped = { [weak self] in
            self?.handleNextTapped()
        }
        window.onRecordTapped = { [weak self] in
            self?.handleRecordTapped()
        }
        window.onWordTapped = { [weak self] word, sentence in
            self?.handleWordTapped(word: word, sentence: sentence, sourceWindow: window)
        }
        window.onWordCardDismissed = { [weak self] in
            self?.handleWordCardDismissed()
        }
    }

    /// Apply a closure to all Island windows
    private func forEachIslandWindow(_ body: (IslandWindow) -> Void) {
        for window in islandWindows.values {
            body(window)
        }
    }

    private func handlePlayTapped() {
        guard let audioPlayer = audioPlayer, let stationStore = stationStore else { return }
        if audioPlayer.isPlaying {
            audioPlayer.stop()
        } else {
            // Resume last station, or fall back to first station
            let station: RadioStation?
            if let current = audioPlayer.currentStation {
                station = current
            } else if let lastId = audioPlayer.lastStationId,
                      let last = stationStore.stations.first(where: { $0.id == lastId }) {
                station = last
            } else {
                station = stationStore.stations.first
            }
            if let station = station {
                audioPlayer.play(station: station)
            }
        }
    }

    private func handleNextTapped() {
        guard let audioPlayer = audioPlayer, let stationStore = stationStore else { return }
        let stations = stationStore.stations
        guard !stations.isEmpty else { return }

        // Find current index from currentStation or lastStationId
        let currentId = audioPlayer.currentStation?.id ?? audioPlayer.lastStationId
        if let currentId = currentId,
           let idx = stations.firstIndex(where: { $0.id == currentId }) {
            let nextIdx = (idx + 1) % stations.count
            audioPlayer.play(station: stations[nextIdx])
        } else {
            audioPlayer.play(station: stations[0])
        }
    }

    // MARK: - Media Key support

    private func setupRemoteCommands() {
        // MPRemoteCommandCenter for system Now Playing integration
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in self?.handlePlayTapped(); return .success }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in self?.audioPlayer?.stop(); return .success }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in self?.handlePlayTapped(); return .success }
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in self?.handleNextTapped(); return .success }
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false

        MPNowPlayingInfoCenter.default().playbackState = .paused
        updateNowPlaying()

        // Monitor media keys globally (no Accessibility permission needed)
        mediaKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleMediaKeyEvent(event)
        }

        // Global hotkey: Cmd+Shift+M to toggle recording
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cmd+Shift+M
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "m" {
                self?.handleRecordTapped()
                return nil
            }
            return event
        }

        appLog("[App] Media key monitor installed")
    }

    private func handleMediaKeyEvent(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }  // 8 = media key subtype

        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isDown = keyState == 0x0A

        guard isDown else { return }

        switch keyCode {
        case 16: // Play/Pause
            handlePlayTapped()
        case 17: // Next
            handleNextTapped()
        default:
            break
        }
    }

    private func updateNowPlaying() {
        var info = [String: Any]()
        let stationName = audioPlayer?.currentStation?.name ?? "Island Radio"
        info[MPMediaItemPropertyTitle] = stationName
        info[MPMediaItemPropertyArtist] = "Island Radio"
        info[MPNowPlayingInfoPropertyPlaybackRate] = audioPlayer?.isPlaying == true ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        info[MPMediaItemPropertyPlaybackDuration] = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = audioPlayer?.isPlaying == true ? .playing : .paused
    }

    private func handleRecordTapped() {
        guard let sttBridge = sttBridge else {
            appLog("[App] Island record tapped but sttBridge is nil!")
            return
        }
        appLog("[App] Island record tapped: isListening=\(sttBridge.isListening), isConnected=\(sttBridge.isConnected)")
        if sttBridge.isListening {
            sttBridge.stopSTT()
        } else {
            let lang = audioPlayer?.currentStation?.language ?? "en-US"
            appLog("[App] Island record: starting STT with lang=\(lang), currentStation=\(audioPlayer?.currentStation?.name ?? "nil")")
            sttBridge.startSTT(lang: lang)
        }
    }

    // MARK: - Word Lookup

    private func handleWordTapped(word: String, sentence: String, sourceWindow: IslandWindow) {
        guard let wordStore = wordStore else { return }
        appLog("[App] Word tapped: '\(word)' in sentence: '\(sentence)'")

        // Immediately highlight the tapped word in all Island windows
        var words = wordStore.learnedWordsSet
        words.insert(word.lowercased())
        forEachIslandWindow { $0.updateLearnedWords(words) }

        // Pause playback
        if audioPlayer?.isPlaying == true {
            audioPlayer?.pause()
            pausedForLookup = true
        }

        // Show loading card only on the window where the word was tapped
        sourceWindow.showWordCardLoading(word: word)

        // Check cache first
        if let cached = wordStore.cachedTranslation(for: word, sentence: sentence) {
            appLog("[App] Using cached translation for '\(word)'")
            sourceWindow.showWordCardResult(word: word, result: cached)
            addToLearningList(word: word, sentence: sentence, result: cached)
            return
        }

        // Query LLM
        let config = LLMConfig.load()
        Task {
            let taskStart = CFAbsoluteTimeGetCurrent()
            do {
                let result = try await LLMService.translateWord(word, sentence: sentence, config: config)
                let elapsed = CFAbsoluteTimeGetCurrent() - taskStart
                appLog("[App] LLM result for '\(word)': \(result.meaning ?? "nil") (total \(String(format: "%.2f", elapsed))s)")

                // Cache the result
                wordStore.cacheTranslation(result, for: word, sentence: sentence)

                // Show result on the source window
                sourceWindow.showWordCardResult(word: word, result: result)

                // Add to learning list
                addToLearningList(word: word, sentence: sentence, result: result)
            } catch {
                appLog("[App] LLM error for '\(word)': \(error.localizedDescription)")
                sourceWindow.showWordCardError(word: word, message: error.localizedDescription)
            }
        }
    }

    private func addToLearningList(word: String, sentence: String, result: TranslationResult) {
        guard let wordStore = wordStore else { return }

        let item = LearningItem(
            id: UUID().uuidString,
            word: word,
            phonetic: result.phonetic,
            rootAnalysis: result.rootAnalysis,
            syllableBreakdown: result.syllableBreakdown,
            meaning: result.meaning,
            example: result.example,
            sentence: sentence,
            sentenceTranslation: result.sentenceTranslation,
            stationName: audioPlayer?.currentStation?.name ?? "Unknown",
            timestamp: Date(),
            mastered: false,
            levels: result.levels
        )
        wordStore.add(item)

        // Update Island highlighting on all windows
        forEachIslandWindow { $0.updateLearnedWords(wordStore.learnedWordsSet) }
    }

    private func handleWordCardDismissed() {
        // Resume playback if it was paused for lookup
        if pausedForLookup {
            audioPlayer?.resume()
            pausedForLookup = false
        }
    }

    @objc private func quitApp() {
        sttBridge?.stop()
        audioPlayer?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - State observation

    private func observeChanges(audioPlayer: AudioPlayer, sttBridge: STTBridgeServer) {
        // Update all Island windows when station/playing state changes
        audioPlayer.$currentStation
            .combineLatest(audioPlayer.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] station, isPlaying in
                if let station = station {
                    self?.forEachIslandWindow {
                        $0.updateStation(name: station.name, color: station.color, isPlaying: isPlaying)
                    }
                } else {
                    // Show last played or first station when nothing is playing
                    let fallback: RadioStation?
                    if let lastId = self?.audioPlayer?.lastStationId,
                       let last = self?.stationStore?.stations.first(where: { $0.id == lastId }) {
                        fallback = last
                    } else {
                        fallback = self?.stationStore?.stations.first
                    }
                    self?.forEachIslandWindow {
                        $0.updateStation(name: fallback?.name ?? "", color: fallback?.color, isPlaying: false)
                    }
                }
                self?.updateNowPlaying()

                // Auto-start STT when playback begins
                if isPlaying, let stt = self?.sttBridge, !stt.isListening {
                    let lang = station?.language ?? "en-US"
                    appLog("[App] Auto-starting STT with lang=\(lang)")
                    stt.startSTT(lang: lang)
                }

                // Update STT language if already listening and station changed
                if isPlaying, let stt = self?.sttBridge, stt.isListening,
                   let lang = station?.language {
                    stt.setLanguage(lang)
                }
            }
            .store(in: &cancellables)

        // Update all Island windows when STT results arrive
        sttBridge.$subtitle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] subtitle in
                self?.forEachIslandWindow { $0.updateSubtitle(subtitle) }
            }
            .store(in: &cancellables)

        // Update all Island windows when STT listening state changes
        sttBridge.$isListening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listening in
                self?.forEachIslandWindow { $0.updateRecording(listening) }
            }
            .store(in: &cancellables)

        // Update all Island windows when word store changes
        if let wordStore = wordStore {
            wordStore.$items
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let ws = self?.wordStore else { return }
                    self?.forEachIslandWindow { $0.updateLearnedWords(ws.learnedWordsSet) }
                }
                .store(in: &cancellables)
        }
    }
}
