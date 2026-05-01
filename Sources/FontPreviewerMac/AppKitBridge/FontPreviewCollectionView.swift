import AppKit
import FontPreviewerCore
import SwiftUI

struct FontPreviewCollectionView: NSViewRepresentable {
    var items: [FontItem]
    var previewText: String
    var fontSize: Double
    var onFavorite: (FontItem) -> Void
    var onCompare: (FontItem) -> Void
    var onInstall: (FontItem) -> Void
    var onCopy: (FontItem) -> Void
    var onSelect: (FontItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 320, height: 180)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

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
                    case .copy:
                        self.parent.onCopy(font)
                    case .select:
                        self.parent.onSelect(font)
                    }
                }
            )
            return previewItem
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let indexPath = indexPaths.first, indexPath.item < parent.items.count else { return }
            parent.onSelect(parent.items[indexPath.item])
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let width = max(280, min(420, collectionView.bounds.width / columns(for: collectionView.bounds.width) - 22))
            return NSSize(width: width, height: 190)
        }

        private func columns(for width: CGFloat) -> CGFloat {
            if width > 1250 { return 3 }
            if width > 760 { return 2 }
            return 1
        }
    }
}

private enum FontPreviewAction {
    case favorite
    case compare
    case install
    case copy
    case select
}

private final class FontPreviewCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FontPreviewCollectionItem")

    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let favoriteButton = NSButton(title: "☆", target: nil, action: nil)
    private let compareButton = NSButton(title: "+", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let installButton = NSButton(title: "安装", target: nil, action: nil)

    private var font: FontItem?
    private var actionHandler: ((FontPreviewAction, FontItem) -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        previewLabel.isEditable = false
        previewLabel.isSelectable = false
        previewLabel.maximumNumberOfLines = 3
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [favoriteButton, compareButton, copyButton, installButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        favoriteButton.action = #selector(toggleFavorite)
        compareButton.action = #selector(toggleCompare)
        copyButton.action = #selector(copyStyle)
        installButton.action = #selector(installFont)

        let header = NSStackView(views: [titleLabel, statusLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let buttons = NSStackView(views: [favoriteButton, copyButton, compareButton, installButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [header, metadataLabel, previewLabel, buttons])
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
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(selectFont))
        view.addGestureRecognizer(click)
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
        metadataLabel.stringValue = "\(font.postScriptName) · \(font.relativePath)"
        statusLabel.stringValue = font.installStatus.displayName
        statusLabel.textColor = color(for: font.installStatus)
        previewLabel.stringValue = previewText.isEmpty ? "输入一些内容以进行预览..." : previewText
        previewLabel.font = NSFont(name: font.postScriptName, size: fontSize) ?? .systemFont(ofSize: fontSize)

        favoriteButton.title = font.isFavorite ? "★" : "☆"
        compareButton.title = font.isCompared ? "−" : "+"
        installButton.isEnabled = font.installStatus.isInstallable && font.isSupportedFontFile
        installButton.title = font.installStatus == .installing ? "安装中" : "安装"
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

    @objc private func copyStyle() {
        perform(.copy)
    }

    @objc private func selectFont() {
        perform(.select)
    }

    private func perform(_ action: FontPreviewAction) {
        guard let font else { return }
        actionHandler?(action, font)
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
