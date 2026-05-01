import FontCopyCore
import SwiftUI

struct PreviewPaneView: View {
    @ObservedObject var store: FontLibraryStore

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)

            Divider()

            if store.fonts.isEmpty {
                emptyState
            } else if store.isShowingSelectedFontDetail, let selectedFont = store.selectedFont {
                FocusedFontDetailView(store: store, font: selectedFont)
            } else {
                VStack(spacing: 0) {
                    if !store.comparedFonts.isEmpty {
                        comparisonStrip
                        Divider()
                    }

                    FontPreviewCollectionView(
                        items: store.visibleFonts,
                        previewText: store.previewText,
                        fontSize: store.fontSize,
                        onFavorite: store.toggleFavorite,
                        onCompare: store.toggleCompare,
                        onInstall: store.install,
                        onCopy: { font, selectedText in
                            store.copyFCPXStyle(font, text: selectedText)
                        },
                        onSelect: store.selectFont
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.detailTitle)
                    .font(.title2.weight(.semibold))
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isInstalling || store.isNormalizingFontNames {
                ProgressView()
                    .controlSize(.small)
            }

            Button("清除比较") {
                store.clearComparison()
            }
            .disabled(store.comparedFonts.isEmpty)

            Button("安装全部未安装") {
                store.confirmAndInstallAllMissing()
            }
            .disabled(store.installableFonts.isEmpty || store.isInstalling || store.isNormalizingFontNames)
            .help("批量安装到 /Library/Fonts，会先显示确认")
        }
    }

    private var summaryText: String {
        if let statusMessage = store.statusMessage {
            return statusMessage
        }

        return "\(store.visibleFonts.count) 个字体 · 未安装 \(store.missingCount) · 冲突 \(store.conflictCount) · 不支持 \(store.unsupportedCount)"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if store.isScanning {
                ProgressView(value: store.scanProgressFraction)
                    .frame(width: 260)
                Text(store.scanProgressText)
                    .font(.title3.weight(.semibold))
                if let currentPath = store.scanProgress?.currentPath {
                    Text(currentPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 420)
                }
            } else {
                Image(systemName: "textformat")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)
                Text("欢迎使用 FontCopy")
                    .font(.title2.weight(.semibold))
                Text("点击工具栏的“导入文件夹”开始扫描本机字体资产。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comparisonStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正在比较 \(store.comparedFonts.count)")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            FontPreviewCollectionView(
                items: store.comparedFonts,
                previewText: store.previewText,
                fontSize: min(store.fontSize, 72),
                onFavorite: store.toggleFavorite,
                onCompare: store.toggleCompare,
                onInstall: store.install,
                onCopy: { font, selectedText in
                    store.copyFCPXStyle(font, text: selectedText)
                },
                onSelect: store.selectFont
            )
            .frame(height: 220)
        }
    }
}

private struct FocusedFontDetailView: View {
    @ObservedObject var store: FontLibraryStore
    let font: FontItem

    private var previewText: String {
        store.previewText.isEmpty ? "输入一些内容以进行预览..." : store.previewText
    }

    private var focusedFontSize: Double {
        min(max(store.fontSize * 1.8, 96), 220)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        store.showAllFonts()
                    } label: {
                        Label("返回列表", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Text(font.installStatus.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusTint)
                }

                SelectableFontPreviewText(
                    text: previewText,
                    postScriptName: font.postScriptName,
                    fontSize: CGFloat(focusedFontSize),
                    alignment: .center,
                    onCopySelection: { selectedText in
                        store.copyFCPXStyle(font, text: selectedText)
                    }
                )
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
                    .padding(32)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Button {
                        store.copyFCPXStyle(font)
                    } label: {
                        Label("复制样式", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        store.toggleFavorite(font)
                    } label: {
                        Label(font.isFavorite ? "已收藏" : "收藏", systemImage: font.isFavorite ? "star.fill" : "star")
                    }

                    Button {
                        store.toggleCompare(font)
                    } label: {
                        Label(font.isCompared ? "移除比较" : "加入比较", systemImage: "plus.square.on.square")
                    }

                    Button {
                        store.install(font)
                    } label: {
                        Label(font.installStatus == .installing ? "安装中" : "安装", systemImage: "arrow.down.circle")
                    }
                    .disabled(!font.installStatus.isInstallable || !font.isSupportedFontFile || store.isInstalling)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    metadataRow("PostScript", font.postScriptName)
                    metadataRow("Family", font.familyName)
                    metadataRow("Style", font.styleName ?? "未知")
                    metadataRow("Category", font.category)
                    metadataRow("Version", font.version ?? "未知")
                    metadataRow("File", font.relativePath)
                    metadataRow("Hash", String(font.fileHash.prefix(12)))
                    if let installError = font.installError {
                        metadataRow("Install Error", installError)
                    }
                }
                .font(.callout)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusTint: Color {
        switch font.installStatus {
        case .installed: return .green
        case .missing: return .orange
        case .unsupported: return .secondary
        case .conflict: return .yellow
        case .installing: return .blue
        case .error: return .red
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "未知" : value)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
