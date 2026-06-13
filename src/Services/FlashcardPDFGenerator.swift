import Foundation
import AppKit
import CoreGraphics

/// Generates a PDF of flashcards from LearningItems.
/// Layout: A4 paper, 3 columns x 4 rows = 12 cards per page.
enum FlashcardPDFGenerator {
    // A4 size in points (72 dpi)
    private static let pageWidth: CGFloat = 595.28
    private static let pageHeight: CGFloat = 841.89
    private static let margin: CGFloat = 24
    private static let cardSpacingH: CGFloat = 7
    private static let cardSpacingV: CGFloat = 7
    private static let columns = 3
    private static let rows = 7
    private static let cardsPerPage = columns * rows

    // Colors
    private static let accentColor = NSColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1)       // blue
    private static let headerBgColor = NSColor(red: 0.22, green: 0.47, blue: 0.87, alpha: 0.08)  // light blue bg
    private static let labelColor = NSColor(red: 0.3, green: 0.55, blue: 0.4, alpha: 1)          // green-ish
    private static let cardBorderColor = NSColor(red: 0.7, green: 0.8, blue: 0.9, alpha: 1)      // soft blue border
    private static let cardBgColor = NSColor(white: 0.995, alpha: 1)

    static func generate(items: [LearningItem]) -> Data {
        let contentWidth = pageWidth - margin * 2
        let contentHeight = pageHeight - margin * 2
        let cardWidth = (contentWidth - cardSpacingH * CGFloat(columns - 1)) / CGFloat(columns)
        let cardHeight = (contentHeight - cardSpacingV * CGFloat(rows - 1)) / CGFloat(rows)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let totalPages = (items.count + cardsPerPage - 1) / cardsPerPage

        for page in 0..<totalPages {
            context.beginPDFPage(nil)

            context.saveGState()
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)

            let startIdx = page * cardsPerPage
            let endIdx = min(startIdx + cardsPerPage, items.count)

            for i in startIdx..<endIdx {
                let localIdx = i - startIdx
                let col = localIdx % columns
                let row = localIdx / columns

                let x = margin + CGFloat(col) * (cardWidth + cardSpacingH)
                let y = margin + CGFloat(row) * (cardHeight + cardSpacingV)

                drawCard(context: context, item: items[i], rect: CGRect(x: x, y: y, width: cardWidth, height: cardHeight))
            }

            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return pdfData as Data
    }

    private static func drawCard(context: CGContext, item: LearningItem, rect: CGRect) {
        let cornerRadius: CGFloat = 5

        // Card background
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setFillColor(cardBgColor.cgColor)
        context.addPath(path)
        context.fillPath()

        // Card border (colored)
        context.setStrokeColor(cardBorderColor.cgColor)
        context.setLineWidth(0.7)
        context.addPath(path)
        context.strokePath()

        // Header background band (top area with accent color)
        let headerHeight: CGFloat = 22
        let headerRect = CGRect(x: rect.minX + 0.5, y: rect.minY + 0.5, width: rect.width - 1, height: headerHeight)
        let headerPath = CGMutablePath()
        headerPath.move(to: CGPoint(x: headerRect.minX + cornerRadius, y: headerRect.minY))
        headerPath.addLine(to: CGPoint(x: headerRect.maxX - cornerRadius, y: headerRect.minY))
        headerPath.addArc(tangent1End: CGPoint(x: headerRect.maxX, y: headerRect.minY),
                          tangent2End: CGPoint(x: headerRect.maxX, y: headerRect.minY + cornerRadius), radius: cornerRadius)
        headerPath.addLine(to: CGPoint(x: headerRect.maxX, y: headerRect.maxY))
        headerPath.addLine(to: CGPoint(x: headerRect.minX, y: headerRect.maxY))
        headerPath.addLine(to: CGPoint(x: headerRect.minX, y: headerRect.minY + cornerRadius))
        headerPath.addArc(tangent1End: CGPoint(x: headerRect.minX, y: headerRect.minY),
                          tangent2End: CGPoint(x: headerRect.minX + cornerRadius, y: headerRect.minY), radius: cornerRadius)
        headerPath.closeSubpath()
        context.setFillColor(headerBgColor.cgColor)
        context.addPath(headerPath)
        context.fillPath()

        // Content
        let padding: CGFloat = 5
        let contentRect = rect.insetBy(dx: padding, dy: padding)

        let titleFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        let phoneticFont = NSFont.systemFont(ofSize: 6, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 5.5, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 6, weight: .regular)
        let smallFont = NSFont.systemFont(ofSize: 5.5, weight: .regular)

        let bodyColor = NSColor.black
        let dimColor = NSColor(white: 0.45, alpha: 1)

        // ── Title line: Word + Phonetic (left) + Levels (right-aligned) ──
        // Vertically center title text within the header band
        let titleLineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let titleY = rect.minY + (headerHeight - titleLineHeight) / 2
        let levelsStr = item.levels?.joined(separator: " · ") ?? ""
        let phonetic = item.phonetic ?? ""
        drawTitleLine(context: context, word: item.word, phonetic: phonetic, levels: levelsStr,
                      wordFont: titleFont, phoneticFont: phoneticFont, levelsFont: smallFont,
                      wordColor: accentColor, phoneticColor: dimColor, levelsColor: accentColor,
                      rect: CGRect(x: contentRect.minX, y: titleY, width: contentRect.width, height: titleLineHeight))

        var curY = rect.minY + headerHeight + 3

        // ── Syllable breakdown (as labeled content) ──
        if let syllable = item.syllableBreakdown, !syllable.isEmpty {
            curY += drawInlineLabel(context: context, label: "拼读: ", text: syllable, labelFont: labelFont, bodyFont: bodyFont,
                                    labelColor: labelColor, bodyColor: bodyColor, rect: contentRect, curY: curY, maxLines: 1)
            curY += 1.5
        }

        // ── Root analysis ──
        if let root = item.rootAnalysis, !root.isEmpty {
            curY += drawInlineLabel(context: context, label: "词根: ", text: root, labelFont: labelFont, bodyFont: bodyFont,
                                    labelColor: labelColor, bodyColor: bodyColor, rect: contentRect, curY: curY, maxLines: 2)
            curY += 1.5
        }

        // ── Meaning ──
        if let meaning = item.meaning, !meaning.isEmpty {
            curY += drawInlineLabel(context: context, label: "释义: ", text: meaning, labelFont: labelFont, bodyFont: bodyFont,
                                    labelColor: labelColor, bodyColor: bodyColor, rect: contentRect, curY: curY, maxLines: 3)
            curY += 1.5
        }

        // ── Example ──
        if let example = item.example, !example.isEmpty, curY < contentRect.maxY - 14 {
            curY += drawInlineLabelHighlighting(context: context, label: "例句: ", text: example, highlightWord: item.word,
                                                labelFont: labelFont, bodyFont: smallFont, highlightFont: NSFont.systemFont(ofSize: 5.5, weight: .bold),
                                                labelColor: labelColor, bodyColor: bodyColor, highlightColor: accentColor,
                                                rect: contentRect, curY: curY, maxLines: 2)
            curY += 1.5
        }

        // ── Sentence ──
        if !item.sentence.isEmpty, curY < contentRect.maxY - 10 {
            curY += drawInlineLabelHighlighting(context: context, label: "原句: ", text: item.sentence, highlightWord: item.word,
                                                labelFont: labelFont, bodyFont: smallFont, highlightFont: NSFont.systemFont(ofSize: 5.5, weight: .bold),
                                                labelColor: labelColor, bodyColor: dimColor, highlightColor: accentColor,
                                                rect: contentRect, curY: curY, maxLines: 2)
            curY += 1
        }

        // ── Sentence translation ──
        if let trans = item.sentenceTranslation, !trans.isEmpty, curY < contentRect.maxY - 8 {
            let remaining = contentRect.maxY - curY
            curY += drawMultilineText(context: context, text: trans, font: smallFont, color: dimColor,
                                      rect: CGRect(x: contentRect.minX, y: curY, width: contentRect.width, height: remaining),
                                      maxLines: 2)
        }
    }

    // MARK: - Helpers

    /// Draw title line: "word /phonetic/" left-aligned, levels right-aligned
    @discardableResult
    private static func drawTitleLine(context: CGContext, word: String, phonetic: String, levels: String,
                                      wordFont: NSFont, phoneticFont: NSFont, levelsFont: NSFont,
                                      wordColor: NSColor, phoneticColor: NSColor, levelsColor: NSColor,
                                      rect: CGRect) -> CGFloat {
        let lineHeight = ceil(wordFont.ascender - wordFont.descender + wordFont.leading)

        // Draw word + phonetic (left)
        let leftAttrStr = NSMutableAttributedString()
        leftAttrStr.append(NSAttributedString(string: word, attributes: [.font: wordFont, .foregroundColor: wordColor]))
        if !phonetic.isEmpty {
            leftAttrStr.append(NSAttributedString(string: "  \(phonetic)", attributes: [.font: phoneticFont, .foregroundColor: phoneticColor]))
        }
        let leftLine = CTLineCreateWithAttributedString(leftAttrStr)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + lineHeight)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(leftLine, context)
        context.restoreGState()

        // Draw levels (right-aligned, same baseline as word)
        if !levels.isEmpty {
            let levelsAttrs: [NSAttributedString.Key: Any] = [.font: levelsFont, .foregroundColor: levelsColor]
            let levelsAttrStr = NSAttributedString(string: levels, attributes: levelsAttrs)
            let levelsLine = CTLineCreateWithAttributedString(levelsAttrStr)
            let levelsWidth = ceil(CTLineGetTypographicBounds(levelsLine, nil, nil, nil))
            let levelsX = rect.maxX - levelsWidth

            context.saveGState()
            context.translateBy(x: levelsX, y: rect.minY + lineHeight)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(levelsLine, context)
            context.restoreGState()
        }

        return lineHeight
    }

    /// Draw "label: text" inline (label and content on the same line, wrapping if needed)
    @discardableResult
    private static func drawInlineLabel(context: CGContext, label: String, text: String,
                                        labelFont: NSFont, bodyFont: NSFont,
                                        labelColor: NSColor, bodyColor: NSColor,
                                        rect: CGRect, curY: CGFloat, maxLines: Int) -> CGFloat {
        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: labelColor]))
        attrStr.append(NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: bodyColor]))

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let lineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        let maxHeight = lineHeight * CGFloat(maxLines) + 2
        let availableHeight = min(rect.maxY - curY, maxHeight)

        let framePath = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: availableHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), framePath, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let lineCount = min(lines.count, maxLines)

        var totalHeight: CGFloat = 0
        for i in 0..<lineCount {
            let line = lines[i]
            context.saveGState()
            context.translateBy(x: rect.minX, y: curY + totalHeight + lineHeight)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            totalHeight += lineHeight
        }

        return totalHeight
    }

    /// Draw "label: text" inline with the target word highlighted (bold + underline)
    @discardableResult
    private static func drawInlineLabelHighlighting(context: CGContext, label: String, text: String, highlightWord: String,
                                                    labelFont: NSFont, bodyFont: NSFont, highlightFont: NSFont,
                                                    labelColor: NSColor, bodyColor: NSColor, highlightColor: NSColor,
                                                    rect: CGRect, curY: CGFloat, maxLines: Int) -> CGFloat {
        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: labelColor]))

        // Split text by the highlight word (case-insensitive) and apply bold+underline
        let lowerText = text.lowercased()
        let lowerWord = highlightWord.lowercased()
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            if let range = lowerText.range(of: lowerWord, range: searchStart..<text.endIndex) {
                // Text before match
                let before = String(text[searchStart..<range.lowerBound])
                if !before.isEmpty {
                    attrStr.append(NSAttributedString(string: before, attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
                }
                // The matched word — bold + underline
                let matched = String(text[range])
                attrStr.append(NSAttributedString(string: matched, attributes: [
                    .font: highlightFont,
                    .foregroundColor: highlightColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]))
                searchStart = range.upperBound
            } else {
                // Remaining text
                let remaining = String(text[searchStart...])
                attrStr.append(NSAttributedString(string: remaining, attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
                break
            }
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let lineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        let maxHeight = lineHeight * CGFloat(maxLines) + 2
        let availableHeight = min(rect.maxY - curY, maxHeight)

        let framePath = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: availableHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), framePath, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let lineCount = min(lines.count, maxLines)

        var totalHeight: CGFloat = 0
        for i in 0..<lineCount {
            let line = lines[i]
            context.saveGState()
            context.translateBy(x: rect.minX, y: curY + totalHeight + lineHeight)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            totalHeight += lineHeight
        }

        return totalHeight
    }

    @discardableResult
    private static func drawText(context: CGContext, text: String, font: NSFont, color: NSColor, rect: CGRect) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + lineHeight)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()

        return lineHeight
    }

    @discardableResult
    private static func drawMultilineText(context: CGContext, text: String, font: NSFont, color: NSColor, rect: CGRect, maxLines: Int) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)

        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxHeight = lineHeight * CGFloat(maxLines) + 2

        let framePath = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: min(rect.height, maxHeight)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), framePath, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let lineCount = min(lines.count, maxLines)

        var totalHeight: CGFloat = 0
        for i in 0..<lineCount {
            let line = lines[i]
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY + totalHeight + lineHeight)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            totalHeight += lineHeight
        }

        return totalHeight
    }
}
