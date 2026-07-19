import AppKit

/// Mirrors the Island content onto the MacBook Pro Touch Bar (2016–2019 models).
///
/// Because Island Radio spends most of its life in the background, we cannot rely
/// on the standard `NSResponder.makeTouchBar()` chain — that only shows a Touch Bar
/// when the app is frontmost. Instead we register a persistent item in the system
/// Control Strip using the private DFR (Digital Function Row) API. The Control Strip
/// button is always visible regardless of which app is focused; tapping it presents
/// a system-modal Touch Bar that carries the full Island UI (station, subtitle,
/// playback controls, and the inline word card).
@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    // Callbacks — wired to the same handlers used by IslandWindow.
    var onPlayTapped: (() -> Void)?
    var onNextTapped: (() -> Void)?
    var onRecordTapped: (() -> Void)?
    /// Called when a word in the subtitle is tapped: (word, fullSentence)
    var onWordTapped: ((String, String) -> Void)?

    // Mirrored Island state
    private var stationName = ""
    private var stationColor: NSColor = .systemGreen
    private var isPlaying = false
    private var isRecording = false
    private var subtitleText = ""
    /// Set of lowercase learned words for gold highlighting.
    private var learnedWords: Set<String> = []
    /// Temporary word-card display, overrides the subtitle while set.
    private var wordCardText: String?

    // Control Strip (persistent) item + its button
    private var stripItem: NSCustomTouchBarItem?
    private let stripButton = NSButton()

    // Modal Touch Bar item views (kept for live updates while presented)
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let recordButton = NSButton()
    /// The subtitle is an NSSegmentedControl with one segment per word: a standard
    /// Touch Bar control that composites reliably in the background AND reports the
    /// exact segment (word) tapped via `selectedSegment`. Segments abut each other,
    /// so it stays dense/readable — unlike separate Touch Bar items, whose fixed
    /// system spacing looked far too sparse; and unlike a single button, which never
    /// delivers a usable tap coordinate (`touchesBegan` never fires, the action's
    /// event location is constant).
    private let subtitleSegments = NSSegmentedControl()
    private var segmentWords: [String] = []
    private let maxSegments = 28
    private var modalTouchBar: NSTouchBar?
    private(set) var isModalPresented = false
    /// `true` once the user has opened the Island bar; drives auto re-presentation so
    /// the full content stays visible when other apps become frontmost.
    private var wantsModalVisible = false

    /// `true` when this machine actually exposes the private DFR API (i.e. it has a Touch Bar).
    let isAvailable: Bool

    override init() {
        isAvailable = TouchBarBridge.isAvailable
        super.init()
        guard isAvailable else {
            appLog("[TouchBar] No Touch Bar detected — controller disabled")
            return
        }
        buildStripItem()
        buildModalItems()
        installControlStripPresence()
        observeAppActivation()
        appLog("[TouchBar] Control Strip presence installed")
    }

    /// The system collapses our tray-anchored modal Touch Bar whenever another app
    /// becomes frontmost. If the user has opened the Island bar, re-present it on every
    /// app activation so the full content (buttons + subtitle) stays visible everywhere.
    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wantsModalVisible else { return }
                self.presentModal()
            }
        }
    }

    // MARK: - Public state updates (called from AppDelegate)

    func updateStation(name: String, color: String?, isPlaying: Bool) {
        guard isAvailable else { return }
        stationName = name
        self.isPlaying = isPlaying
        if let hex = color, let c = NSColor(hex: hex) {
            stationColor = c
        }
        refreshStripButton()
        refreshPlayButton()
        refreshSubtitleView()
    }

    func updateRecording(_ recording: Bool) {
        guard isAvailable else { return }
        isRecording = recording
        refreshRecordButton()
    }

    func updateSubtitle(_ subtitle: SubtitleState) {
        guard isAvailable else { return }
        subtitleText = subtitle.text
        // A fresh subtitle supersedes any lingering word-card text.
        if !subtitle.text.isEmpty {
            wordCardText = nil
        }
        refreshSubtitleView()
    }

    /// Update the set of learned words used for gold highlighting.
    func updateLearnedWords(_ words: Set<String>) {
        guard isAvailable else { return }
        learnedWords = words
        refreshSubtitleView()
    }

    /// Show a looked-up word + meaning in the subtitle slot until the next subtitle arrives.
    func showWordCard(word: String, meaning: String?) {
        guard isAvailable else { return }
        let m = (meaning?.isEmpty == false) ? meaning! : "…"
        wordCardText = "\(word) — \(m)"
        refreshSubtitleView()
    }

    func dismissWordCard() {
        guard isAvailable else { return }
        wordCardText = nil
        refreshSubtitleView()
    }

    // MARK: - Control Strip item

    private func buildStripItem() {
        stripButton.bezelStyle = .rounded
        stripButton.isBordered = true
        stripButton.imagePosition = .imageOnly
        stripButton.imageScaling = .scaleProportionallyDown
        stripButton.lineBreakMode = .byTruncatingHead
        stripButton.target = self
        stripButton.action = #selector(stripTapped)

        let item = NSCustomTouchBarItem(identifier: .islandStrip)
        item.view = stripButton
        stripItem = item
        refreshStripButton()
    }

    private func installControlStripPresence() {
        guard let item = stripItem else { return }
        TouchBarBridge.addSystemTrayItem(item)
        TouchBarBridge.setControlStripPresence(item.identifier, visible: true)
    }

    private func refreshStripButton() {
        // Radio glyph, tinted with the station color while playing (grey otherwise).
        let icon = NSImage(systemSymbolName: "radio", accessibilityDescription: "Island Radio")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        stripButton.image = icon
        stripButton.contentTintColor = isPlaying ? stationColor : NSColor.secondaryLabelColor

        // Icon only in the Control Strip — the live, highlightable, tappable subtitle
        // (and station name) live in the expanded modal Touch Bar.
        stripButton.title = ""
    }

    @objc private func stripTapped() {
        if wantsModalVisible {
            wantsModalVisible = false
            dismissModal()
        } else {
            wantsModalVisible = true
            presentModal()
        }
    }

    // MARK: - Modal Touch Bar

    private func buildModalItems() {
        configureSymbolButton(playButton, symbol: "play.fill", action: #selector(playTapped))
        configureSymbolButton(nextButton, symbol: "forward.end.fill", action: #selector(nextTapped))
        configureSymbolButton(recordButton, symbol: "mic.slash.fill", action: #selector(recordTapped))

        // Subtitle: one segment per word (see property doc). Segments abut each other
        // (dense, readable) and report the exact tapped word via `selectedSegment`.
        // NOTE: only `.rounded` composites reliably in the background modal Touch Bar
        // (`.smallSquare` renders as blank there), so keep it.
        subtitleSegments.segmentStyle = .rounded
        subtitleSegments.trackingMode = .momentary
        subtitleSegments.font = Self.subtitleFont
        subtitleSegments.target = self
        subtitleSegments.action = #selector(subtitleSegmentTapped(_:))

        refreshPlayButton()
        refreshRecordButton()
        refreshSubtitleView()
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
    }

    private func presentModal() {
        guard let item = stripItem else { return }
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.islandPlay, .islandNext, .islandRecord, .fixedSpaceSmall, .islandSubtitle]
        modalTouchBar = touchBar

        TouchBarBridge.setModalShowsCloseBox(true)
        TouchBarBridge.presentSystemModal(touchBar, systemTrayItemIdentifier: item.identifier)
        isModalPresented = true
        appLog("[TouchBar] Presented modal Island Touch Bar")
    }

    private func dismissModal() {
        guard let touchBar = modalTouchBar else { return }
        TouchBarBridge.dismissSystemModal(touchBar)
        modalTouchBar = nil
        isModalPresented = false
        appLog("[TouchBar] Dismissed modal Island Touch Bar")
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .islandPlay:
            return customItem(identifier, view: playButton)
        case .islandNext:
            return customItem(identifier, view: nextButton)
        case .islandRecord:
            return customItem(identifier, view: recordButton)
        case .islandSubtitle:
            return customItem(identifier, view: subtitleSegments)
        default:
            return nil
        }
    }

    private func customItem(_ identifier: NSTouchBarItem.Identifier, view: NSView) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        return item
    }

    // MARK: - Button actions

    @objc private func playTapped() { onPlayTapped?() }
    @objc private func nextTapped() { onNextTapped?() }
    @objc private func recordTapped() { onRecordTapped?() }

    /// A subtitle word segment was tapped — look up the exact word it maps to.
    @objc private func subtitleSegmentTapped(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0, idx < segmentWords.count else { return }
        let word = segmentWords[idx]
        appLog("[TouchBar] segment tapped idx=\(idx) word=\(word)")
        guard !word.isEmpty else { return }
        onWordTapped?(word, subtitleText)
    }

    // MARK: - Item refresh

    private func refreshPlayButton() {
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func refreshRecordButton() {
        let symbol = isRecording ? "mic.fill" : "mic.slash.fill"
        recordButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        recordButton.contentTintColor = isRecording ? .systemRed : nil
    }

    private func refreshSubtitleView() {
        let raw = wordCardText ?? subtitleText
        // Keep only the most recent words that fit a FIXED text-width budget (drops
        // whole leading lines, so text jumps on a line break like the Island). The
        // budget is a hand-tuned constant — adjust `subtitleFitWidth` to fill more/less.
        let display = IslandCapsuleView.dropOverflowLines(
            raw.isEmpty ? stationName : raw,
            maxLines: 1,
            width: Self.subtitleFitWidth,
            font: Self.subtitleFont
        )
        let tokens = display
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .prefix(maxSegments)
        applySegments(Array(tokens))
    }

    /// Render the given words into the segmented control (one image segment each,
    /// gold when learned, with edge insets on the first/last word).
    private func applySegments(_ tokens: [String]) {
        segmentWords = tokens.map { $0.trimmingCharacters(in: CharacterSet.letters.inverted) }
        subtitleSegments.segmentCount = tokens.count
        let lastIndex = tokens.count - 1
        for (i, token) in tokens.enumerated() {
            let clean = segmentWords[i].lowercased()
            let isLearned = !clean.isEmpty && learnedWords.contains(clean)
            let leftInset: CGFloat = (i == 0) ? Self.edgeInset : 0
            let rightInset: CGFloat = (i == lastIndex) ? Self.edgeInset : 0
            let image = Self.wordImage(token, learned: isLearned, leftInset: leftInset, rightInset: rightInset)
            subtitleSegments.setLabel("", forSegment: i)
            subtitleSegments.setImage(image, forSegment: i)
            subtitleSegments.setImageScaling(.scaleNone, forSegment: i)
            subtitleSegments.setWidth(image.size.width + Self.segmentPadding, forSegment: i)
        }
    }

    /// Font used for the Touch Bar subtitle.
    private static let subtitleFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    /// Horizontal padding added to each segment's measured text width.
    private static let segmentPadding: CGFloat = 4
    /// Transparent breathing room baked into the first/last word's image.
    private static let edgeInset: CGFloat = 10
    /// Hand-tuned text-width budget (points) used to pick how many words to show.
    /// Increase to fill more of the Touch Bar, decrease if the right side clips.
    private static let subtitleFitWidth: CGFloat = 500
    private static let normalColor = NSColor.white
    private static let learnedColor = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0) // gold

    /// Render a single word to an image, colored gold when learned, with optional
    /// transparent left/right insets (used to pad the first/last word).
    private static func wordImage(_ text: String, learned: Bool, leftInset: CGFloat, rightInset: CGFloat) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: learned ? learnedColor : normalColor,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: ceil(textSize.width) + leftInset + rightInset,
                          height: ceil(textSize.height))
        let image = NSImage(size: size)
        image.lockFocus()
        (text as NSString).draw(at: NSPoint(x: leftInset, y: 0), withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = false // keep our colors; don't let the control tint it
        return image
    }
}

// MARK: - Touch Bar item identifiers

extension NSTouchBarItem.Identifier {
    static let islandStrip = NSTouchBarItem.Identifier("com.islandradio.touchbar.strip")
    static let islandPlay = NSTouchBarItem.Identifier("com.islandradio.touchbar.play")
    static let islandNext = NSTouchBarItem.Identifier("com.islandradio.touchbar.next")
    static let islandRecord = NSTouchBarItem.Identifier("com.islandradio.touchbar.record")
    static let islandSubtitle = NSTouchBarItem.Identifier("com.islandradio.touchbar.subtitle")
}

// MARK: - Private DFR (Touch Bar) API bridge

/// Thin wrapper around the private DFRFoundation / AppKit symbols required to place
/// a persistent item in the Control Strip and present a system-modal Touch Bar.
/// All symbols are resolved dynamically so the app still links & runs on Macs
/// without a Touch Bar (every call becomes a safe no-op there).
private enum TouchBarBridge {
    private typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void
    private typealias ShowCloseBoxFn = @convention(c) (Bool) -> Void

    private static let dfrHandle: UnsafeMutableRawPointer? = {
        // Try the versioned path first, then the framework binary directly.
        let paths = [
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation",
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW) { return handle }
        }
        return nil
    }()

    private static let setPresenceFn: SetPresenceFn? = {
        guard let handle = dfrHandle,
              let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return nil }
        return unsafeBitCast(sym, to: SetPresenceFn.self)
    }()

    private static let showCloseBoxFn: ShowCloseBoxFn? = {
        guard let handle = dfrHandle,
              let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return nil }
        return unsafeBitCast(sym, to: ShowCloseBoxFn.self)
    }()

    /// A Touch Bar exists only when the private presence symbol is resolvable.
    static var isAvailable: Bool { setPresenceFn != nil }

    static func setControlStripPresence(_ identifier: NSTouchBarItem.Identifier, visible: Bool) {
        setPresenceFn?(identifier.rawValue as NSString, visible)
    }

    static func setModalShowsCloseBox(_ show: Bool) {
        showCloseBoxFn?(show)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        let cls: AnyObject = NSTouchBarItem.self
        let sel = NSSelectorFromString("addSystemTrayItem:")
        if cls.responds(to: sel) {
            _ = cls.perform(sel, with: item)
        }
    }

    static func presentSystemModal(_ touchBar: NSTouchBar, systemTrayItemIdentifier identifier: NSTouchBarItem.Identifier) {
        let cls: AnyObject = NSTouchBar.self
        // Selector name differs across macOS versions; try the modern one, then the legacy fallback.
        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:",
        ]
        for name in selectors {
            let sel = NSSelectorFromString(name)
            if cls.responds(to: sel) {
                _ = cls.perform(sel, with: touchBar, with: identifier.rawValue as NSString)
                return
            }
        }
    }

    static func dismissSystemModal(_ touchBar: NSTouchBar) {
        let cls: AnyObject = NSTouchBar.self
        let selectors = [
            "dismissSystemModalTouchBar:",
            "dismissSystemModalFunctionBar:",
        ]
        for name in selectors {
            let sel = NSSelectorFromString(name)
            if cls.responds(to: sel) {
                _ = cls.perform(sel, with: touchBar)
                return
            }
        }
    }
}
