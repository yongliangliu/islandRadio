import AppKit

/// The notch-style content view inside the Island window.
/// Shape: flat top edge, inverted (concave) corners at top-left/top-right,
/// normal rounded corners at bottom-left/bottom-right — mimicking the
/// macOS Dynamic Island / notch cutout.
final class IslandCapsuleView: NSView {
    // Subviews
    private let backgroundShape = CAShapeLayer()
    private let stationDot = CALayer()
    private let stationLabel = NSTextField(labelWithString: "")
    private let subtitleTextView: ClickableSubtitleView
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let recordButton = NSButton()

    // Word card subviews (inline below subtitle)
    private let wordCardSeparator = CALayer()
    private let wcWordLabel = NSTextField(labelWithString: "")
    private let wcPhoneticLabel = NSTextField(labelWithString: "")
    private let wcLevelsLabel = NSTextField(labelWithString: "")
    private let wcMeaningLabel = NSTextField(labelWithString: "")
    private let wcDetailLabel = NSTextField(labelWithString: "")
    private let wcLoadingIndicator = NSProgressIndicator()
    private let wcCloseButton = NSButton()

    // Callbacks for button actions
    var onPlayTapped: (() -> Void)?
    var onNextTapped: (() -> Void)?
    var onRecordTapped: (() -> Void)?
    /// Called when a word in the subtitle is clicked: (word, fullSentence)
    var onWordTapped: ((String, String) -> Void)?
    /// Called when the inline word card is dismissed
    var onWordCardDismissed: (() -> Void)?

    // State
    private(set) var currentSubtitle = SubtitleState.empty
    private var isPlaying = false
    private var isHovered = false
    private var isRecording = false
    private var stationColor: NSColor = .systemGreen
    /// Set of lowercase learned words for highlighting
    var learnedWords: Set<String> = []
    /// Whether the inline word card is currently showing
    private(set) var isShowingWordCard = false
    /// The fixed header height (= menu bar / collapsed height), set by IslandWindow
    var fixedHeaderHeight: CGFloat = 30

    // Layout constants
    /// Radius for the inverted (concave) corners at top — where the flat top edge
    /// transitions into the straight sides, curving inward like the macOS notch.
    private let topInvertedRadius: CGFloat = 12
    /// Radius for the normal (convex) bottom corners
    private let bottomRadius: CGFloat = 14
    private let hPadding: CGFloat = 14
    private let dotSize: CGFloat = 8
    /// Button icon configuration
    private let btnSymbolSize: CGFloat = 13
    private let playSymbolSize: CGFloat = 14
    private let btnTintColor: NSColor = NSColor.white.withAlphaComponent(0.55)

    override init(frame: NSRect) {
        subtitleTextView = ClickableSubtitleView(
            frame: NSRect(x: 0, y: 0, width: frame.width - 14 * 2, height: 30)
        )
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        // Notch-shaped background — pure black to blend with the notch
        backgroundShape.fillColor = NSColor.black.cgColor
        backgroundShape.path = notchPath(for: bounds)
        layer!.addSublayer(backgroundShape)

        // Station dot (pulsing green indicator)
        stationDot.frame = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        stationDot.cornerRadius = dotSize / 2
        stationDot.backgroundColor = NSColor.systemGreen.cgColor
        stationDot.opacity = 0.4
        layer!.addSublayer(stationDot)

        // Station name label
        stationLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stationLabel.textColor = .white
        stationLabel.backgroundColor = .clear
        stationLabel.drawsBackground = false
        stationLabel.isBezeled = false
        stationLabel.isEditable = false
        stationLabel.isSelectable = false
        stationLabel.lineBreakMode = .byTruncatingTail
        stationLabel.maximumNumberOfLines = 1
        stationLabel.cell?.isScrollable = false
        stationLabel.cell?.wraps = false
        addSubview(stationLabel)

        // Clickable subtitle text view — max 2 visible lines
        subtitleTextView.alphaValue = 0
        subtitleTextView.onWordClicked = { [weak self] word in
            guard let self = self else { return }
            self.onWordTapped?(word, self.currentSubtitle.text)
        }
        addSubview(subtitleTextView)

        // Play button (SF Symbol)
        playButton.bezelStyle = .inline
        playButton.isBordered = false
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(.init(pointSize: playSymbolSize, weight: .medium))
        playButton.contentTintColor = btnTintColor
        playButton.imageScaling = .scaleNone
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.alphaValue = 1
        addSubview(playButton)

        // Next button (SF Symbol)
        nextButton.bezelStyle = .inline
        nextButton.isBordered = false
        nextButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: "Next")?
            .withSymbolConfiguration(.init(pointSize: btnSymbolSize, weight: .medium))
        nextButton.contentTintColor = btnTintColor
        nextButton.imageScaling = .scaleNone
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.alphaValue = 1
        addSubview(nextButton)

        // Record button (SF Symbol)
        recordButton.bezelStyle = .inline
        recordButton.isBordered = false
        recordButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record")?
            .withSymbolConfiguration(.init(pointSize: btnSymbolSize, weight: .medium))
        recordButton.contentTintColor = btnTintColor
        recordButton.imageScaling = .scaleNone
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        recordButton.alphaValue = 1
        addSubview(recordButton)

        // ── Inline word card subviews (below subtitle) ──
        // Separator line
        wordCardSeparator.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        wordCardSeparator.isHidden = true
        layer!.addSublayer(wordCardSeparator)

        // Word title
        wcWordLabel.font = .systemFont(ofSize: 14, weight: .bold)
        wcWordLabel.textColor = .white
        wcWordLabel.backgroundColor = .clear
        wcWordLabel.drawsBackground = false
        wcWordLabel.isBezeled = false
        wcWordLabel.isEditable = false
        wcWordLabel.isSelectable = false
        wcWordLabel.maximumNumberOfLines = 1
        wcWordLabel.isHidden = true
        addSubview(wcWordLabel)

        // Phonetic
        wcPhoneticLabel.font = .systemFont(ofSize: 11, weight: .regular)
        wcPhoneticLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        wcPhoneticLabel.backgroundColor = .clear
        wcPhoneticLabel.drawsBackground = false
        wcPhoneticLabel.isBezeled = false
        wcPhoneticLabel.isEditable = false
        wcPhoneticLabel.isSelectable = false
        wcPhoneticLabel.maximumNumberOfLines = 1
        wcPhoneticLabel.isHidden = true
        addSubview(wcPhoneticLabel)

        // Levels (right of phonetic)
        wcLevelsLabel.font = .systemFont(ofSize: 10, weight: .medium)
        wcLevelsLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        wcLevelsLabel.backgroundColor = .clear
        wcLevelsLabel.drawsBackground = false
        wcLevelsLabel.isBezeled = false
        wcLevelsLabel.isEditable = false
        wcLevelsLabel.isSelectable = false
        wcLevelsLabel.maximumNumberOfLines = 1
        wcLevelsLabel.alignment = .right
        wcLevelsLabel.isHidden = true
        addSubview(wcLevelsLabel)

        // Meaning
        wcMeaningLabel.font = .systemFont(ofSize: 12, weight: .medium)
        wcMeaningLabel.textColor = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        wcMeaningLabel.backgroundColor = .clear
        wcMeaningLabel.drawsBackground = false
        wcMeaningLabel.isBezeled = false
        wcMeaningLabel.isEditable = false
        wcMeaningLabel.isSelectable = false
        wcMeaningLabel.lineBreakMode = .byWordWrapping
        wcMeaningLabel.maximumNumberOfLines = 2
        wcMeaningLabel.cell?.wraps = true
        wcMeaningLabel.isHidden = true
        addSubview(wcMeaningLabel)

        // Detail (root analysis, example, sentence translation)
        wcDetailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        wcDetailLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        wcDetailLabel.backgroundColor = .clear
        wcDetailLabel.drawsBackground = false
        wcDetailLabel.isBezeled = false
        wcDetailLabel.isEditable = false
        wcDetailLabel.isSelectable = false
        wcDetailLabel.lineBreakMode = .byWordWrapping
        wcDetailLabel.maximumNumberOfLines = 4
        wcDetailLabel.cell?.wraps = true
        wcDetailLabel.isHidden = true
        addSubview(wcDetailLabel)

        // Loading indicator
        wcLoadingIndicator.style = .spinning
        wcLoadingIndicator.controlSize = .small
        wcLoadingIndicator.isDisplayedWhenStopped = false
        wcLoadingIndicator.isHidden = true
        addSubview(wcLoadingIndicator)

        // Close button
        wcCloseButton.bezelStyle = .inline
        wcCloseButton.isBordered = false
        wcCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        wcCloseButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        wcCloseButton.imageScaling = .scaleNone
        wcCloseButton.target = self
        wcCloseButton.action = #selector(wordCardCloseTapped)
        wcCloseButton.isHidden = true
        addSubview(wcCloseButton)

        appLog("[CapsuleView] init frame=\(frame), layer=\(String(describing: layer)), bounds=\(bounds)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()

        // Update notch-shaped background path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundShape.path = notchPath(for: bounds)
        CATransaction.commit()

        // ── macOS coords: y=0 is bottom, y increases upward ──
        // Visual order top→bottom: header | word card | separator | subtitle
        // macOS y order bottom→top: subtitle | separator | word card | header

        // Header elements fixed at top, vertically centered within menu bar height
        let headerCenterY = bounds.height - fixedHeaderHeight / 2

        let labelX = hPadding + dotSize + 6
        let btnSize: CGFloat = 16
        let btnSpacing: CGFloat = 6
        let rightButtonsWidth = hPadding + btnSize * 3 + btnSpacing * 2
        let labelHeight: CGFloat = 18
        stationLabel.frame = NSRect(
            x: labelX,
            y: headerCenterY - labelHeight / 2,
            width: bounds.width - labelX - rightButtonsWidth,
            height: labelHeight
        )

        // Station dot — vertically centered with station label
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stationDot.frame = CGRect(
            x: hPadding,
            y: headerCenterY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        CATransaction.commit()

        // Control buttons — right-aligned, vertically centered in header
        let totalWidth = btnSize * 3 + btnSpacing * 2
        let startX = bounds.width - hPadding - totalWidth

        playButton.frame = NSRect(
            x: startX,
            y: headerCenterY - btnSize / 2,
            width: btnSize, height: btnSize
        )
        nextButton.frame = NSRect(
            x: startX + btnSize + btnSpacing,
            y: headerCenterY - btnSize / 2,
            width: btnSize, height: btnSize
        )
        recordButton.frame = NSRect(
            x: startX + (btnSize + btnSpacing) * 2,
            y: headerCenterY - btnSize / 2,
            width: btnSize, height: btnSize
        )

        let contentWidth = bounds.width - hPadding * 2

        // ── Build layout from bottom up ──
        var curY: CGFloat = Self.bottomPadding - 4  // start from bottom

        // 1) Subtitle — at the very bottom
        let subtitleHeight = max(0, subtitleDesiredHeight(forWidth: bounds.width))
        subtitleTextView.frame = NSRect(
            x: hPadding, y: curY,
            width: contentWidth, height: subtitleHeight
        )
        curY += subtitleHeight

        // 2) Word card (if showing) — above subtitle
        if isShowingWordCard {
            // Separator line between subtitle and word card
            curY += 4  // small gap before separator
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wordCardSeparator.frame = CGRect(x: hPadding, y: curY, width: contentWidth, height: 0.5)
            CATransaction.commit()
            curY += 0.5 + Self.wcInternalPadding

            // Detail — bottom of word card area (visually lowest in card)
            wcDetailLabel.preferredMaxLayoutWidth = contentWidth
            let detailHeight = wcDetailLabel.intrinsicContentSize.height
            if detailHeight > 0 {
                wcDetailLabel.frame = NSRect(
                    x: hPadding, y: curY,
                    width: contentWidth, height: detailHeight
                )
                curY += detailHeight + Self.wcLineSpacing
            }

            // Meaning
            wcMeaningLabel.preferredMaxLayoutWidth = contentWidth
            let meaningHeight = max(16, wcMeaningLabel.intrinsicContentSize.height)
            wcMeaningLabel.frame = NSRect(
                x: hPadding, y: curY,
                width: contentWidth, height: meaningHeight
            )
            curY += meaningHeight + Self.wcLineSpacing

            // Word + phonetic on same line
            let wordWidth = min(wcWordLabel.intrinsicContentSize.width + 4, bounds.width * 0.4)
            wcWordLabel.frame = NSRect(
                x: hPadding, y: curY,
                width: wordWidth, height: 18
            )
            let phoneticX = hPadding + wordWidth + 6
            let closeBtnSize: CGFloat = 16
            let levelsWidth = min(wcLevelsLabel.intrinsicContentSize.width + 4, bounds.width * 0.3)
            let phoneticWidth = bounds.width - phoneticX - hPadding - closeBtnSize - levelsWidth - 8
            wcPhoneticLabel.frame = NSRect(
                x: phoneticX, y: curY + 3,
                width: max(phoneticWidth, 0), height: 14
            )
            wcLevelsLabel.frame = NSRect(
                x: bounds.width - hPadding - closeBtnSize - levelsWidth - 4, y: curY + 3,
                width: levelsWidth, height: 14
            )

            // Close button — aligned with levels label
            wcCloseButton.frame = NSRect(
                x: bounds.width - hPadding - closeBtnSize, y: curY + 2,
                width: closeBtnSize, height: closeBtnSize
            )

            // Loading indicator — centered in word card area
            let wcMidY = (subtitleTextView.frame.maxY + curY + 18) / 2
            wcLoadingIndicator.frame = NSRect(
                x: bounds.width / 2 - 8, y: wcMidY - 8,
                width: 16, height: 16
            )
        }
    }

    // MARK: - Layout constants for height calculation
    /// Header row height (dot + station label area)
    static let headerHeight: CGFloat = 30
    /// Vertical padding below subtitle
    static let bottomPadding: CGFloat = 8
    /// Maximum number of visible subtitle lines
    static let maxSubtitleLines: Int = 2
    /// Word card internal padding and spacing
    static let wcInternalPadding: CGFloat = 8
    static let wcLineSpacing: CGFloat = 6

    /// Calculate the subtitle text height alone (without header/padding).
    private func subtitleDesiredHeight(forWidth width: CGFloat) -> CGFloat {
        let text = currentSubtitle.text
        guard !text.isEmpty else { return 0 }

        let availableWidth = width - hPadding * 2
        let font = ClickableSubtitleView.subtitleFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxTextHeight = lineHeight * CGFloat(Self.maxSubtitleLines)

        let textRect = (text as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        return min(ceil(textRect.height), maxTextHeight)
    }

    /// Calculate the word card content height (gap + separator + labels).
    private func wordCardContentHeight(forWidth width: CGFloat) -> CGFloat {
        guard isShowingWordCard else { return 0 }

        let contentWidth = width - hPadding * 2
        var h: CGFloat = 4 + 0.5 + Self.wcInternalPadding  // gap + separator + top padding
        h += 18  // word + phonetic line
        h += Self.wcLineSpacing

        // Meaning height
        wcMeaningLabel.preferredMaxLayoutWidth = contentWidth
        h += max(16, wcMeaningLabel.intrinsicContentSize.height)
        h += Self.wcLineSpacing

        // Detail height
        wcDetailLabel.preferredMaxLayoutWidth = contentWidth
        let detailH = wcDetailLabel.intrinsicContentSize.height
        if detailH > 0 {
            h += detailH
        }
        h += Self.wcInternalPadding  // bottom padding (between detail and separator)

        return h
    }

    /// Calculate the desired panel height based on subtitle text + optional word card.
    /// Returns collapsed height when empty, otherwise header + subtitle + word card.
    func desiredHeight(forWidth width: CGFloat, collapsedHeight: CGFloat) -> CGFloat {
        let text = currentSubtitle.text
        guard !text.isEmpty else {
            return collapsedHeight
        }

        let subtitleH = subtitleDesiredHeight(forWidth: width)
        let wordCardH = wordCardContentHeight(forWidth: width)

        return Self.headerHeight + subtitleH + wordCardH + Self.bottomPadding
    }

    // MARK: - Public updates

    func updateStation(name: String, color: String?, isPlaying: Bool) {
        stationLabel.stringValue = name
        self.isPlaying = isPlaying

        if let hex = color {
            stationColor = NSColor(hex: hex) ?? .systemGreen
        }
        stationDot.backgroundColor = stationColor.cgColor

        // Update play button icon based on state
        playButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: isPlaying ? "Pause" : "Play"
        )?.withSymbolConfiguration(.init(pointSize: isPlaying ? btnSymbolSize : playSymbolSize, weight: .medium))

        if isPlaying {
            addPulseAnimation()
        } else {
            stationDot.removeAnimation(forKey: "pulse")
            stationDot.opacity = 0.4
        }

        updateVisibility()
    }

    func updateRecording(_ recording: Bool) {
        isRecording = recording
        recordButton.contentTintColor = recording ? .systemRed : btnTintColor
        recordButton.image = NSImage(
            systemSymbolName: recording ? "mic.fill" : "mic.slash.fill",
            accessibilityDescription: recording ? "Stop Recording" : "Start Recording"
        )?.withSymbolConfiguration(.init(pointSize: btnSymbolSize, weight: .medium))

        // Change dot color: red when recording, station color otherwise
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stationDot.backgroundColor = recording ? NSColor.systemRed.cgColor : stationColor.cgColor
        CATransaction.commit()
    }

    func updateSubtitle(_ subtitle: SubtitleState) {
        currentSubtitle = subtitle

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            if subtitle.text.isEmpty {
                subtitleTextView.animator().alphaValue = 0
            } else {
                // Drop completed first lines when text exceeds 2 visible lines
                let displayText = Self.dropOverflowLines(
                    subtitle.text,
                    maxLines: Self.maxSubtitleLines,
                    width: (superview?.frame.width ?? bounds.width) - hPadding * 2,
                    font: ClickableSubtitleView.subtitleFont
                )
                subtitleTextView.setText(displayText, learnedWords: learnedWords)
                subtitleTextView.animator().alphaValue = 1
            }
        }
    }

    /// If `text` exceeds `maxLines` when laid out at `width`, repeatedly remove
    /// the entire first visual line until it fits. This avoids per-character
    /// jitter — text only shifts when a full line overflows.
    private static func dropOverflowLines(_ text: String, maxLines: Int, width: CGFloat, font: NSFont) -> String {
        guard width > 0, maxLines > 0 else { return text }

        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxHeight = lineHeight * CGFloat(maxLines) + 2

        // Quick check: does the full text fit?
        func fitsInMaxLines(_ s: String) -> Bool {
            let rect = (s as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return ceil(rect.height) <= maxHeight
        }

        if fitsInMaxLines(text) { return text }

        // Use NSTextStorage + NSLayoutManager to find visual line breaks
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        // Force layout
        layoutManager.ensureLayout(for: container)

        // Collect the character range of each visual line
        var lineRanges: [NSRange] = []
        var index = 0
        let fullLength = (text as NSString).length
        while index < fullLength {
            var lineRange = NSRange(location: 0, length: 0)
            layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &lineRange)
            let charRange = layoutManager.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            lineRanges.append(charRange)
            index = NSMaxRange(charRange)
        }

        // Drop lines from the front until we have at most maxLines remaining
        guard lineRanges.count > maxLines else { return text }
        let linesToDrop = lineRanges.count - maxLines
        let dropEnd = NSMaxRange(lineRanges[linesToDrop - 1])
        return (text as NSString).substring(from: dropEnd)
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        updateVisibility()
    }

    // MARK: - Visibility logic

    /// Controls which elements are visible based on isPlaying + isHovered state:
    /// - Station name always visible (when set); dot only when playing
    /// - Not playing: show play + next buttons
    /// - Playing, not hovered: hide buttons
    /// - Playing, hovered: show pause + next + record buttons
    private func updateVisibility() {
        let hasStation = !stationLabel.stringValue.isEmpty
        let showButtons: Bool

        if !isPlaying {
            showButtons = true
        } else if isHovered {
            showButtons = true
        } else {
            showButtons = false
        }

        stationLabel.isHidden = !hasStation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stationDot.isHidden = !hasStation
        CATransaction.commit()

        playButton.isHidden = !showButtons
        nextButton.isHidden = !showButtons
        recordButton.isHidden = !showButtons || !isPlaying

        needsLayout = true
    }

    // MARK: - Inline Word Card

    private func setWordCardSubviewsHidden(_ hidden: Bool) {
        wordCardSeparator.isHidden = hidden
        wcWordLabel.isHidden = hidden
        wcPhoneticLabel.isHidden = hidden
        wcLevelsLabel.isHidden = hidden
        wcMeaningLabel.isHidden = hidden
        wcDetailLabel.isHidden = hidden
        wcCloseButton.isHidden = hidden
        if hidden {
            wcLoadingIndicator.isHidden = true
            wcLoadingIndicator.stopAnimation(nil)
        }
    }

    /// Show loading state for word lookup
    func showWordCardLoading(word: String) {
        isShowingWordCard = true
        setWordCardSubviewsHidden(false)
        wcWordLabel.stringValue = word
        wcPhoneticLabel.stringValue = ""
        wcLevelsLabel.stringValue = ""
        wcMeaningLabel.stringValue = "查询中..."
        wcDetailLabel.stringValue = ""
        wcLoadingIndicator.isHidden = false
        wcLoadingIndicator.startAnimation(nil)
        needsLayout = true
    }

    /// Show word translation result
    func showWordCardResult(word: String, result: TranslationResult) {
        wcLoadingIndicator.stopAnimation(nil)
        wcLoadingIndicator.isHidden = true
        wcWordLabel.stringValue = word
        // Combine phonetic and syllable breakdown on the same line
        var phoneticParts: [String] = []
        if let p = result.phonetic, !p.isEmpty { phoneticParts.append(p) }
        if let s = result.syllableBreakdown, !s.isEmpty { phoneticParts.append(s) }
        wcPhoneticLabel.stringValue = phoneticParts.joined(separator: "  ")
        wcLevelsLabel.stringValue = result.levels?.joined(separator: " · ") ?? ""
        wcMeaningLabel.stringValue = result.meaning ?? "无释义"

        var details: [String] = []
        if let root = result.rootAnalysis, !root.isEmpty {
            details.append("词根: \(root)")
        }
        if let example = result.example, !example.isEmpty {
            details.append("例: \(example)")
        }
        if let sentTrans = result.sentenceTranslation, !sentTrans.isEmpty {
            details.append("句意: \(sentTrans)")
        }
        wcDetailLabel.stringValue = details.joined(separator: "\n")
        needsLayout = true
    }

    /// Show word lookup error
    func showWordCardError(word: String, message: String) {
        wcLoadingIndicator.stopAnimation(nil)
        wcLoadingIndicator.isHidden = true
        wcWordLabel.stringValue = word
        wcPhoneticLabel.stringValue = ""
        wcLevelsLabel.stringValue = ""
        wcMeaningLabel.stringValue = "查询失败"
        wcDetailLabel.stringValue = message
        needsLayout = true
    }

    /// Dismiss the inline word card
    func dismissWordCard() {
        isShowingWordCard = false
        setWordCardSubviewsHidden(true)
        needsLayout = true
    }

    @objc private func wordCardCloseTapped() {
        dismissWordCard()
        // Notify window to resume playback but keep card area
        onWordCardDismissed?()
    }

    // MARK: - Notch shape path

    /// Build a CGPath that mimics the macOS notch / Dynamic Island shape
    /// using cubic Bézier curves for smooth continuous-curvature corners
    /// (squircle style, like Apple's native cornerCurve = .continuous).
    ///
    /// ```
    /// screen top ────────────────────────────
    ///            ╮                          ╭   ← inverted (concave) corners at top
    ///            │                          │
    ///            │                          │   ← straight sides
    ///            │                          │
    ///            ╰──────────────────────────╯   ← normal convex corners at bottom
    /// ```
    ///
    /// macOS coordinate system: origin at bottom-left, y increases upward.
    private func notchPath(for rect: CGRect) -> CGPath {
        let w = rect.width
        let h = rect.height
        let ir = min(topInvertedRadius, h / 2, w / 2)
        let br = min(bottomRadius, h / 2, w / 2)

        // Bézier handle factor for continuous curvature (squircle).
        // Apple uses ~1.28 × radius for the total "influence zone" of each corner.
        // The handle offset from the corner tangent point is ~0.55 × radius
        // (compared to 0.5523 for a perfect circular arc).
        let k: CGFloat = 0.55

        let path = CGMutablePath()

        // ── Start: top-left, at the beginning of the top edge ──
        path.move(to: CGPoint(x: 0, y: h))

        // ── Top edge (left → right) ──
        path.addLine(to: CGPoint(x: w, y: h))

        // ── Top-right inverted (concave) corner ──
        // Goes from (w, h) curving inward down to (w, h - ir)
        path.addCurve(
            to: CGPoint(x: w, y: h - ir),
            control1: CGPoint(x: w + ir * k, y: h),
            control2: CGPoint(x: w, y: h - ir + ir * k)
        )

        // ── Right side straight down ──
        path.addLine(to: CGPoint(x: w, y: br))

        // ── Bottom-right normal (convex) corner ──
        // Goes from (w, br) curving inward to (w - br, 0)
        path.addCurve(
            to: CGPoint(x: w - br, y: 0),
            control1: CGPoint(x: w, y: br - br * k),
            control2: CGPoint(x: w - br + br * k, y: 0)
        )

        // ── Bottom edge (right → left) ──
        path.addLine(to: CGPoint(x: br, y: 0))

        // ── Bottom-left normal (convex) corner ──
        // Goes from (br, 0) curving inward to (0, br)
        path.addCurve(
            to: CGPoint(x: 0, y: br),
            control1: CGPoint(x: br - br * k, y: 0),
            control2: CGPoint(x: 0, y: br - br * k)
        )

        // ── Left side straight up ──
        path.addLine(to: CGPoint(x: 0, y: h - ir))

        // ── Top-left inverted (concave) corner ──
        // Goes from (0, h - ir) curving inward up to (0, h)
        path.addCurve(
            to: CGPoint(x: 0, y: h),
            control1: CGPoint(x: 0, y: h - ir + ir * k),
            control2: CGPoint(x: -ir * k, y: h)
        )

        path.closeSubpath()
        return path
    }

    // MARK: - Button actions

    @objc private func playTapped() {
        onPlayTapped?()
    }

    @objc private func nextTapped() {
        onNextTapped?()
    }

    @objc private func recordTapped() {
        onRecordTapped?()
    }

    // MARK: - Pulse animation for playing indicator

    private func addPulseAnimation() {
        stationDot.opacity = 1.0
        stationDot.removeAnimation(forKey: "pulse")

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        stationDot.add(pulse, forKey: "pulse")
    }
}

// MARK: - ClickableSubtitleView

/// A custom NSView that renders subtitle text as individually clickable words.
/// Learned words are highlighted with a gold color.
final class ClickableSubtitleView: NSView {
    static let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let normalColor = NSColor.white.withAlphaComponent(0.8)
    private static let learnedColor = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0) // gold

    /// Called when a word is clicked
    var onWordClicked: ((String) -> Void)?

    private var attributedText = NSMutableAttributedString()
    private var wordRanges: [(range: NSRange, word: String)] = []
    private var currentText = ""

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer: NSTextContainer

    override init(frame: NSRect) {
        textContainer = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        super.init(frame: frame)

        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 2
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    /// Set the subtitle text, highlighting learned words.
    func setText(_ text: String, learnedWords: Set<String>) {
        currentText = text
        wordRanges.removeAll()

        let attrStr = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        // Split text into tokens: words and separators
        let pattern = "([a-zA-Z''-]+|[^a-zA-Z''-]+)"
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var currentLocation = 0
        for match in matches {
            let range = match.range
            let token = nsText.substring(with: range)

            // Check if this token is a word (letters only)
            let isWord = token.rangeOfCharacter(from: .letters) != nil
            let isLearned = isWord && learnedWords.contains(token.lowercased())

            var attrs: [NSAttributedString.Key: Any] = [
                .font: Self.subtitleFont,
                .paragraphStyle: paragraphStyle,
            ]

            if isLearned {
                attrs[.foregroundColor] = Self.learnedColor
            } else {
                attrs[.foregroundColor] = Self.normalColor
            }

            let tokenAttr = NSAttributedString(string: token, attributes: attrs)
            let insertRange = NSRange(location: currentLocation, length: token.count)
            attrStr.append(tokenAttr)

            if isWord {
                wordRanges.append((range: insertRange, word: token))
            }

            currentLocation += token.count
        }

        attributedText = attrStr
        textStorage.setAttributedString(attrStr)
        textContainer.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard textStorage.length > 0 else { return }
        textContainer.size = NSSize(width: bounds.width, height: bounds.height)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        // Find which word was clicked
        let glyphIndex = layoutManager.glyphIndex(for: locationInView, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        for (range, word) in wordRanges {
            if charIndex >= range.location && charIndex < range.location + range.length {
                // Clean the word: strip punctuation from edges
                let cleaned = word.trimmingCharacters(in: CharacterSet.letters.inverted)
                if !cleaned.isEmpty {
                    onWordClicked?(cleaned)
                }
                return
            }
        }
    }

    // Show pointer cursor over words
    override func resetCursorRects() {
        guard textStorage.length > 0 else { return }
        textContainer.size = NSSize(width: bounds.width, height: bounds.height)
        layoutManager.ensureLayout(for: textContainer)

        for (range, _) in wordRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            addCursorRect(boundingRect, cursor: .pointingHand)
        }
    }

    override func layout() {
        super.layout()
        textContainer.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
    }
}

// MARK: - NSColor hex extension

extension NSColor {
    convenience init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }

        guard hexStr.count == 6,
              let rgb = UInt64(hexStr, radix: 16) else { return nil }

        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
