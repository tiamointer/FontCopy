import AppKit
import FontCopyCore
import SwiftUI

struct FontPreviewCollectionView: NSViewRepresentable {
    var items: [FontItem]
    var previewText: String
    var fontSize: Double
    var onFavorite: (FontItem) -> Void
    var onCompare: (FontItem) -> Void
    var onInstall: (FontItem) -> Void
    var onNormalize: (FontItem) -> Void
    var onCopy: (FontItem, String?) -> Void
    var onSelect: (FontItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = LeftAlignedFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(
            FontPreviewCollectionItem.self,
            forItemWithIdentifier: FontPreviewCollectionItem.reuseIdentifier
        )
        collectionView.backgroundColors = [.clear]

        context.coordinator.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.collectionView?.collectionViewLayout?.invalidateLayout()
        context.coordinator.collectionView?.reloadData()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var parent: FontPreviewCollectionView
        weak var collectionView: NSCollectionView?

        init(parent: FontPreviewCollectionView) {
            self.parent = parent
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: FontPreviewCollectionItem.reuseIdentifier,
                for: indexPath
            )

            guard let previewItem = item as? FontPreviewCollectionItem else {
                return item
            }

            let font = parent.items[indexPath.item]
            previewItem.configure(
                font: font,
                previewText: parent.previewText,
                fontSize: parent.fontSize,
                actionHandler: { [weak self] action, font in
                    guard let self else { return }
                    switch action {
                    case .favorite:
                        self.parent.onFavorite(font)
                    case .compare:
                        self.parent.onCompare(font)
                    case .install:
                        self.parent.onInstall(font)
                    case .normalize:
                        self.parent.onNormalize(font)
                    case .copy(let selectedText):
                        self.parent.onCopy(font, selectedText)
                    case .select:
                        self.parent.onSelect(font)
                    }
                }
            )
            return previewItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let metrics = layoutMetrics(for: collectionView.bounds.width)
            return NSSize(width: metrics.itemWidth, height: 178)
        }

        private func layoutMetrics(for width: CGFloat) -> (columns: Int, itemWidth: CGFloat) {
            let inset: CGFloat = 32
            let spacing: CGFloat = 16
            let minimumReadableWidth: CGFloat = 340
            let availableWidth = max(260, width - inset)
            let columns = max(
                1,
                min(5, Int((availableWidth + spacing) / (minimumReadableWidth + spacing)))
            )
            let itemWidth = floor((availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            return (columns, itemWidth)
        }
    }
}

private final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let attributes = super.layoutAttributesForElements(in: rect).map {
            $0.copy() as! NSCollectionViewLayoutAttributes
        }

        var currentRowY: CGFloat?
        var left = sectionInset.left

        for attribute in attributes where attribute.representedElementCategory == .item {
            if currentRowY == nil || abs(attribute.frame.minY - currentRowY!) > 1 {
                currentRowY = attribute.frame.minY
                left = sectionInset.left
            }

            var frame = attribute.frame
            frame.origin.x = left
            attribute.frame = frame
            left = frame.maxX + minimumInteritemSpacing
        }

        return attributes
    }
}

private enum FontPreviewAction {
    case favorite
    case compare
    case install
    case normalize
    case copy(String?)
    case select
}

private final class FontPreviewCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FontPreviewCollectionItem")

    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let previewTextView = FontCopySelectableTextView()
    private let favoriteButton = NSButton(title: "☆", target: nil, action: nil)
    private let compareButton = NSButton(title: "比较", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let normalizeButton = NSButton(title: "规范化", target: nil, action: nil)
    private let installButton = NSButton(title: "安装", target: nil, action: nil)
    private let doubleClickGesture = NSClickGestureRecognizer()

    private var font: FontItem?
    private var actionHandler: ((FontPreviewAction, FontItem) -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        doubleClickGesture.numberOfClicksRequired = 2
        doubleClickGesture.delaysPrimaryMouseButtonEvents = false
        doubleClickGesture.target = self
        doubleClickGesture.action = #selector(openDetail)
        view.addGestureRecognizer(doubleClickGesture)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        statusIconView.setContentHuggingPriority(.required, for: .horizontal)
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        previewTextView.maximumNumberOfLines = 2
        previewTextView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [favoriteButton, copyButton, compareButton, normalizeButton, installButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        favoriteButton.action = #selector(toggleFavorite)
        compareButton.action = #selector(toggleCompare)
        copyButton.action = #selector(copyStyle)
        normalizeButton.action = #selector(normalizeFontName)
        installButton.action = #selector(installFont)

        let header = NSStackView(views: [titleLabel, statusIconView])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [favoriteButton, copyButton, compareButton, normalizeButton, installButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [header, metadataLabel, previewTextView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
            previewTextView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewTextView.heightAnchor.constraint(equalToConstant: 78)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        font = nil
        actionHandler = nil
    }

    func configure(
        font: FontItem,
        previewText: String,
        fontSize: Double,
        actionHandler: @escaping (FontPreviewAction, FontItem) -> Void
    ) {
        self.font = font
        self.actionHandler = actionHandler

        titleLabel.stringValue = font.displayName
        metadataLabel.stringValue = metadataText(for: font)
        metadataLabel.isHidden = metadataLabel.stringValue.isEmpty
        statusIconView.image = NSImage(systemSymbolName: statusSymbol(for: font.installStatus), accessibilityDescription: font.installStatus.displayName)
        statusIconView.contentTintColor = color(for: font.installStatus)
        statusIconView.toolTip = font.installStatus.displayName
        previewTextView.configure(
            text: previewText.isEmpty ? "输入一些内容以进行预览..." : previewText,
            postScriptName: font.postScriptName,
            fontSize: CGFloat(fontSize),
            alignment: .left
        )
        previewTextView.copySelectedText = { [weak self] selectedText in
            self?.copyText(selectedText)
        }

        favoriteButton.title = font.isFavorite ? "★" : "☆"
        favoriteButton.toolTip = font.isFavorite ? "从收藏夹移除" : "添加到收藏夹"
        copyButton.toolTip = "复制 FCPX 富文本样式"
        compareButton.title = "比较"
        compareButton.state = font.isCompared ? .on : .off
        compareButton.toolTip = font.isCompared ? "从比较区移除此字体" : "把此字体加入比较区"
        normalizeButton.isHidden = !font.canNormalizeInternalName
        normalizeButton.toolTip = "按文件名改写字体内部名称，并创建 .bak 备份"
        installButton.isHidden = !(font.installStatus.isInstallable && font.isSupportedFontFile)
        installButton.isEnabled = font.installStatus.isInstallable && font.isSupportedFontFile
        installButton.title = font.installStatus == .installing ? "安装中" : "安装"
        installButton.toolTip = installToolTip(for: font)
    }

    @objc private func toggleFavorite() {
        perform(.favorite)
    }

    @objc private func toggleCompare() {
        perform(.compare)
    }

    @objc private func installFont() {
        perform(.install)
    }

    @objc private func normalizeFontName() {
        perform(.normalize)
    }

    @objc private func copyStyle() {
        perform(.copy(nil))
    }

    @objc private func openDetail() {
        let location = doubleClickGesture.location(in: view)
        let hitView = view.hitTest(location)
        guard shouldOpenDetail(from: hitView) else { return }
        perform(.select)
    }

    private func shouldOpenDetail(from hitView: NSView?) -> Bool {
        guard let hitView else { return true }
        if hitView == previewTextView || hitView.isDescendant(of: previewTextView) {
            return false
        }

        let actionViews = [favoriteButton, compareButton, copyButton, normalizeButton, installButton]
        return !actionViews.contains { hitView == $0 || hitView.isDescendant(of: $0) }
    }

    private func copyText(_ selectedText: String) {
        perform(.copy(selectedText))
    }

    private func perform(_ action: FontPreviewAction) {
        guard let font else { return }
        actionHandler?(action, font)
    }

    private func installToolTip(for font: FontItem) -> String {
        if font.installStatus == .installing {
            return "正在安装此字体"
        }
        if font.installStatus.isInstallable && font.isSupportedFontFile {
            return "安装此字体到 /Library/Fonts，需要管理员授权"
        }
        if !font.isSupportedFontFile {
            return "此格式暂不支持系统安装"
        }
        return "当前状态为“\(font.installStatus.displayName)”，无需安装"
    }

    private func metadataText(for font: FontItem) -> String {
        var parts: [String] = []
        if !font.familyName.isSameDisplayText(as: font.displayName) {
            parts.append(font.familyName)
        }

        let location = locationText(for: font)
        if !location.isEmpty {
            parts.append(location)
        }

        return parts.joined(separator: " · ")
    }

    private func locationText(for font: FontItem) -> String {
        let cleanRelativePath = font.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativeURL = URL(fileURLWithPath: cleanRelativePath)
        let filenameStem = relativeURL.deletingPathExtension().lastPathComponent
        let category = PathUtilities.category(for: cleanRelativePath)
        let hasCategory = category != "未分类"

        if filenameStem.isSameDisplayText(as: font.displayName)
            || filenameStem.isSameDisplayText(as: font.familyName) {
            return hasCategory ? category : ""
        }

        return cleanRelativePath
    }

    private func statusSymbol(for status: FontInstallStatus) -> String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .missing: return "arrow.down.circle.fill"
        case .unsupported: return "nosign"
        case .conflict: return "exclamationmark.triangle.fill"
        case .installing: return "clock.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for status: FontInstallStatus) -> NSColor {
        switch status {
        case .installed: return .systemGreen
        case .missing: return .systemOrange
        case .unsupported: return .secondaryLabelColor
        case .conflict: return .systemYellow
        case .installing: return .systemBlue
        case .error: return .systemRed
        }
    }
}

private extension String {
    func isSameDisplayText(as other: String) -> Bool {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(other.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
