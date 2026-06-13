import AppKit
import Combine

/// The Island floating window — a capsule-shaped panel that sits at the top center
/// of the screen, flush with the screen's top edge.
///
/// Uses CALayer for rounded corners and Core Animation for smooth transitions.
/// Width is dynamic: adjusts to content between minWidth and maxWidth.
final class IslandWindow: NSPanel {
    static let minWidth: CGFloat = 416
    static let maxWidthRatio: CGFloat = 0.22  // ~1/5 of screen width

    /// Collapsed height matching the menu bar height of the pinned screen.
    let collapsedHeight: CGFloat

    /// Compute collapsed height to match the screen's menu bar / notch area.
    private static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        // Notch screens report safeAreaInsets.top (e.g. 32pt on MacBook Pro)
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            return safeTop + 1  // +1 to fully cover the notch area
        }
        // For screens with a visible menu bar, use frame - visibleFrame
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar > 0 {
            return menuBar
        }
        // Fallback for non-primary screens: standard menu bar height
        return NSStatusBar.system.thickness + 2  // ~24pt
    }

    private let capsuleView: IslandCapsuleView
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var collapseTimer: Timer?
    private var wordCardDismissTimer: Timer?
    private var currentWidth: CGFloat

    /// Timer: hover 3s → hide subtitle
    private var subtitleHideTimer: Timer?
    /// Timer: hidden 5s → restore subtitle
    private var subtitleRestoreTimer: Timer?
    /// Whether subtitle is temporarily hidden by hover
    private var isSubtitleHiddenByHover = false

    /// External callback when word card is dismissed (resume playback etc.)
    private var _onWordCardDismissed: (() -> Void)?

    // Callbacks for capsule button actions
    var onPlayTapped: (() -> Void)? {
        get { capsuleView.onPlayTapped }
        set { capsuleView.onPlayTapped = newValue }
    }
    var onNextTapped: (() -> Void)? {
        get { capsuleView.onNextTapped }
        set { capsuleView.onNextTapped = newValue }
    }
    var onRecordTapped: (() -> Void)? {
        get { capsuleView.onRecordTapped }
        set { capsuleView.onRecordTapped = newValue }
    }
    /// Called when a word in the subtitle is clicked: (word, fullSentence)
    var onWordTapped: ((String, String) -> Void)? {
        get { capsuleView.onWordTapped }
        set { capsuleView.onWordTapped = newValue }
    }

    func updateRecording(_ recording: Bool) {
        capsuleView.updateRecording(recording)
    }

    /// Update the set of learned words for subtitle highlighting
    func updateLearnedWords(_ words: Set<String>) {
        capsuleView.learnedWords = words
        // Re-render current subtitle to reflect new highlights
        capsuleView.updateSubtitle(capsuleView.currentSubtitle)
    }

    // MARK: - Word Card (delegates to capsuleView)

    /// Show loading state for word lookup
    func showWordCardLoading(word: String) {
        wordCardDismissTimer?.invalidate()
        wordCardDismissTimer = nil
        // Cancel hover-hide when user is interacting with word card
        subtitleHideTimer?.invalidate()
        subtitleHideTimer = nil
        capsuleView.showWordCardLoading(word: word)
        resizeForContent()
    }

    /// Show word translation result
    func showWordCardResult(word: String, result: TranslationResult) {
        capsuleView.showWordCardResult(word: word, result: result)
        resizeForContent()
        scheduleWordCardDismiss()
    }

    /// Show word lookup error
    func showWordCardError(word: String, message: String) {
        capsuleView.showWordCardError(word: word, message: message)
        resizeForContent()
        scheduleWordCardDismiss()
    }

    /// Dismiss the word card and resize
    func dismissWordCard() {
        wordCardDismissTimer?.invalidate()
        wordCardDismissTimer = nil
        capsuleView.dismissWordCard()
        // Resize back to subtitle or collapsed
        if !capsuleView.currentSubtitle.text.isEmpty {
            resizeForContent()
        } else if !isHovered {
            resizeToCollapsed()
        } else {
            performCollapse()
        }
    }

    /// Auto-dismiss word card after 10 seconds
    private func scheduleWordCardDismiss() {
        wordCardDismissTimer?.invalidate()
        wordCardDismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.capsuleView.isShowingWordCard else { return }
                self.dismissWordCard()
                self._onWordCardDismissed?()
            }
        }
    }

    /// Called when word card is dismissed (to resume playback)
    var onWordCardDismissed: (() -> Void)? {
        get { _onWordCardDismissed }
        set { _onWordCardDismissed = newValue }
    }

    /// The screen this Island window is pinned to. Set once on init, never follows the active screen.
    let pinnedScreen: NSScreen

    /// Create an Island window pinned to the given screen.
    init(screen: NSScreen) {
        pinnedScreen = screen
        let screenFrame = screen.frame
        collapsedHeight = Self.menuBarHeight(for: screen)

        let maxWidth = floor(screenFrame.width * Self.maxWidthRatio)
        let initialWidth = max(Self.minWidth, min(Self.minWidth, maxWidth))
        currentWidth = initialWidth

        // Position: top center of screen, top edge flush with screen top
        let x = screenFrame.midX - initialWidth / 2
        let y = screenFrame.maxY - collapsedHeight

        capsuleView = IslandCapsuleView(
            frame: NSRect(x: 0, y: 0, width: initialWidth, height: collapsedHeight)
        )
        capsuleView.fixedHeaderHeight = collapsedHeight

        super.init(
            contentRect: NSRect(x: x, y: y, width: initialWidth, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Panel configuration for menu-bar integration
        self.level = .statusBar + 1
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.ignoresMouseEvents = false

        // Single content view — capsule handles everything
        self.contentView = capsuleView

        // Intercept word card dismiss to also resize window
        capsuleView.onWordCardDismissed = { [weak self] in
            guard let self = self else { return }
            self.dismissWordCard()
            self._onWordCardDismissed?()
        }

        setupTracking()

        // Hide during Space-switch animation, show after it completes.
        // 1. When the app's occlusion state changes, hide or show accordingly.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if !NSApp.occlusionState.contains(.visible) {
                self.alphaValue = 0
                appLog("[Island] Occlusion state: not visible, hiding")
            } else {
                // App became visible again — restore if not deliberately hidden
                if self.alphaValue == 0 {
                    self.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        self.animator().alphaValue = 1
                    }
                    appLog("[Island] Occlusion state: visible again, restoring")
                }
            }
        }

        // 2. When the active space finishes changing, fade back in.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Small delay to ensure the animation has fully settled
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.alphaValue = 0
                self.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.animator().alphaValue = 1
                }
            }
        }

        appLog("[Island] Window frame: \(NSStringFromRect(self.frame)), screen: \(NSStringFromRect(screenFrame))")
    }

    // MARK: - Public API

    func updateStation(name: String, color: String?, isPlaying: Bool) {
        capsuleView.updateStation(name: name, color: color, isPlaying: isPlaying)
    }

    func updateSubtitle(_ subtitle: SubtitleState) {
        // During hover-hide, don't display — the restore timer will show latest
        if isSubtitleHiddenByHover {
            return
        }

        capsuleView.updateSubtitle(subtitle)

        if !subtitle.text.isEmpty {
            resizeForContent()
        } else if !isHovered {
            resizeToCollapsed()
        }
    }

    func clearSubtitle() {
        capsuleView.updateSubtitle(.empty)
        if !isHovered {
            resizeToCollapsed()
        }
    }

    func reposition() {
        let screen = pinnedScreen
        let x = screen.frame.midX - frame.width / 2
        let y = screen.frame.maxY - frame.height
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Mouse tracking

    private func setupTracking() {
        guard let cv = contentView else { return }
        let area = NSTrackingArea(
            rect: cv.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        cv.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        collapseTimer?.invalidate()
        collapseTimer = nil
        if !capsuleView.currentSubtitle.text.isEmpty && !isSubtitleHiddenByHover {
            resizeForContent()
        }
        capsuleView.setHovered(true)

        // Start hide timer only if word card is not showing
        if !capsuleView.isShowingWordCard {
            startSubtitleHideTimer()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        capsuleView.setHovered(false)

        // Cancel the hide timer (hasn't fired yet)
        subtitleHideTimer?.invalidate()
        subtitleHideTimer = nil

        if capsuleView.currentSubtitle.text.isEmpty && !isSubtitleHiddenByHover {
            resizeToCollapsed()
        }
    }

    // MARK: - Dynamic resize (width + height)

    /// Resize window to fit current content (subtitle + optional word card).
    /// The capsuleView's desiredHeight() accounts for both subtitle and word card.
    private func resizeForContent() {
        collapseTimer?.invalidate()
        collapseTimer = nil

        let screen = pinnedScreen
        let maxWidth = floor(screen.frame.width * Self.maxWidthRatio)
        let targetWidth = max(Self.minWidth, maxWidth)
        let targetHeight = capsuleView.desiredHeight(forWidth: targetWidth, collapsedHeight: collapsedHeight)

        let newX = screen.frame.midX - targetWidth / 2
        let newY = screen.frame.maxY - targetHeight
        let newFrame = NSRect(x: newX, y: newY, width: targetWidth, height: targetHeight)

        guard !frame.equalTo(newFrame) else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }
        currentWidth = targetWidth
    }

    /// Collapse back to minWidth + collapsedHeight after subtitle clears.
    private func resizeToCollapsed() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performCollapse()
            }
        }
    }

    private func performCollapse() {
        let screen = pinnedScreen
        let targetWidth = Self.minWidth
        let targetHeight = collapsedHeight

        let newX = screen.frame.midX - targetWidth / 2
        let newY = screen.frame.maxY - targetHeight
        let newFrame = NSRect(x: newX, y: newY, width: targetWidth, height: targetHeight)

        guard !frame.equalTo(newFrame) else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }
        currentWidth = targetWidth
    }

    private func scheduleCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performCollapse()
            }
        }
    }

    // MARK: - Hover-hide subtitle

    /// After hovering 3s, hide subtitle area (collapse). Playback continues.
    private func startSubtitleHideTimer() {
        subtitleHideTimer?.invalidate()
        subtitleHideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hoverHideSubtitle()
            }
        }
    }

    private func hoverHideSubtitle() {
        subtitleHideTimer = nil
        guard !isSubtitleHiddenByHover else { return }
        guard !capsuleView.currentSubtitle.text.isEmpty else { return }
        guard !capsuleView.isShowingWordCard else { return }

        isSubtitleHiddenByHover = true

        // Clear subtitle and collapse to header-only
        capsuleView.updateSubtitle(.empty)
        performCollapse()

        appLog("[Island] Subtitle hidden by hover")

        // Auto-restore after 5 seconds regardless of hover state
        subtitleRestoreTimer?.invalidate()
        subtitleRestoreTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hoverRestoreSubtitle()
            }
        }
    }

    private func hoverRestoreSubtitle() {
        subtitleRestoreTimer = nil
        guard isSubtitleHiddenByHover else { return }

        isSubtitleHiddenByHover = false
        appLog("[Island] Subtitle restored after hover-hide")

        // If still hovered and no word card, restart the hide timer
        if isHovered && !capsuleView.isShowingWordCard {
            startSubtitleHideTimer()
        }
    }
}
