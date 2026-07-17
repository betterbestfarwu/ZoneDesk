import AppKit

final class ZoneFileTitleLayout {
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private let glyphRange: NSRange

    let lineCount: Int
    let usesMiddleTruncation: Bool
    let lineBreakMode: NSLineBreakMode
    let textBounds: NSRect

    static func make(
        displayName: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> ZoneFileTitleLayout {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let wrapped = build(
            displayName: displayName,
            font: font,
            maxWidth: maxWidth,
            height: lineHeight * CGFloat(max(displayName.count, 2)),
            maximumNumberOfLines: 0,
            lineBreakMode: .byCharWrapping,
            usesMiddleTruncation: false
        )
        guard wrapped.lineCount > 2 else {
            return wrapped
        }

        return build(
            displayName: displayName,
            font: font,
            maxWidth: maxWidth,
            height: lineHeight,
            maximumNumberOfLines: 1,
            lineBreakMode: .byTruncatingMiddle,
            usesMiddleTruncation: true
        )
    }

    func draw(at origin: NSPoint, alpha: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.setAlpha(alpha)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        context.restoreGState()
    }

    private static func build(
        displayName: String,
        font: NSFont,
        maxWidth: CGFloat,
        height: CGFloat,
        maximumNumberOfLines: Int,
        lineBreakMode: NSLineBreakMode,
        usesMiddleTruncation: Bool
    ) -> ZoneFileTitleLayout {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = lineBreakMode

        let textStorage = NSTextStorage(
            string: displayName,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: max(1, maxWidth), height: max(1, height))
        )
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        textContainer.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineCount += 1
        }

        return ZoneFileTitleLayout(
            textStorage: textStorage,
            layoutManager: layoutManager,
            textContainer: textContainer,
            glyphRange: glyphRange,
            lineCount: lineCount,
            usesMiddleTruncation: usesMiddleTruncation,
            lineBreakMode: lineBreakMode,
            textBounds: layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        )
    }

    private init(
        textStorage: NSTextStorage,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        glyphRange: NSRange,
        lineCount: Int,
        usesMiddleTruncation: Bool,
        lineBreakMode: NSLineBreakMode,
        textBounds: NSRect
    ) {
        self.textStorage = textStorage
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        self.glyphRange = glyphRange
        self.lineCount = lineCount
        self.usesMiddleTruncation = usesMiddleTruncation
        self.lineBreakMode = lineBreakMode
        self.textBounds = textBounds
    }
}
