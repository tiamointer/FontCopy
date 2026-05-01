import AppKit
import SwiftUI

struct SelectableFontPreviewText: NSViewRepresentable {
    var text: String
    var postScriptName: String
    var fontSize: CGFloat
    var alignment: NSTextAlignment = .left
    var onCopySelection: (String) -> Void

    func makeNSView(context: Context) -> FontCopySelectableTextView {
        let textView = FontCopySelectableTextView()
        textView.copySelectedText = onCopySelection
        return textView
    }

    func updateNSView(_ nsView: FontCopySelectableTextView, context: Context) {
        nsView.copySelectedText = onCopySelection
        nsView.configure(
            text: text,
            postScriptName: postScriptName,
            fontSize: fontSize,
            alignment: alignment
        )
    }
}

final class FontCopySelectableTextView: NSTextView {
    var copySelectedText: ((String) -> Void)?
    var maximumNumberOfLines: Int = 0 {
        didSet {
            textContainer?.maximumNumberOfLines = maximumNumberOfLines
        }
    }

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        backgroundColor = .clear
        wantsLayer = true
        layer?.masksToBounds = true
        importsGraphics = false
        allowsUndo = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextContainerSize(for: newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        super.draw(dirtyRect.intersection(bounds))
        NSGraphicsContext.restoreGraphicsState()
    }

    func configure(
        text: String,
        postScriptName: String,
        fontSize: CGFloat,
        alignment: NSTextAlignment
    ) {
        let font = NSFont(name: postScriptName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        textContainer?.lineBreakMode = .byWordWrapping
        textContainer?.maximumNumberOfLines = maximumNumberOfLines

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let selectedRange = selectedRange()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        updateTextContainerSize(for: frame.size)
        if selectedRange.location != NSNotFound, NSMaxRange(selectedRange) <= (string as NSString).length {
            setSelectedRange(selectedRange)
        }
        needsDisplay = true
    }

    private func updateTextContainerSize(for size: NSSize) {
        textContainer?.containerSize = NSSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let swiftRange = Range(range, in: string) else {
            super.copy(sender)
            return
        }

        copySelectedText?(String(string[swiftRange]))
    }
}
