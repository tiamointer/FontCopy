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

            if let normalize = store.normalizeProgress {
                progressStrip(
                    fraction: normalize.fractionCompleted,
                    primary: normalize.displayText,
                    secondary: normalize.currentName
                )
                Divider()
            } else if let install = store.installProgress {
                progressStrip(
                    fraction: install.fractionCompleted,
                    primary: install.displayText,
                    secondary: install.currentName
                )
                Divider()
            }

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
                        onNormalize: store.normalizeFontName,
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

            Button("规范化当前") {
                store.normalizeVisibleFonts()
            }
            .disabled(store.normalizableVisibleFontFiles.isEmpty || store.isNormalizingFontNames || store.isInstalling || store.isScanning)
            .help("把当前可见范围内文件名与内部名不一致的字体批量规范化")

            Button("安装当前未安装") {
                store.confirmAndInstallAllMissing()
            }
            .disabled(store.installableFonts.isEmpty || store.isInstalling || store.isNormalizingFontNames)
            .help("批量安装当前可见范围内的未安装字体到 /Library/Fonts，会先显示确认")
        }
    }

    private func progressStrip(fraction: Double, primary: String, secondary: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            Text(primary)
                .font(.callout)
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial)
    }

    private var summaryText: String {
        if store.normalizeProgress != nil || store.installProgress != nil {
            return staticCountsText
        }
        if let statusMessage = store.statusMessage {
            return statusMessage
        }
        return staticCountsText
    }

    private var staticCountsText: String {
        "\(store.visibleFonts.count) 个字体 · 未安装 \(store.visibleMissingCount) · 冲突 \(store.visibleConflictCount) · 不支持 \(store.visibleUnsupportedCount)"
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
                onNormalize: store.normalizeFontName,
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
                    sourceURL: font.sourceURL,
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
                        Label("比较", systemImage: "plus.square.on.square")
                    }

                    if font.canNormalizeInternalName {
                        Button {
                            store.normalizeFontName(font)
                        } label: {
                            Label("规范化", systemImage: "pencil.and.outline")
                        }
                    }

                    if font.installStatus.isInstallable && font.isSupportedFontFile {
                        Button {
                            store.install(font)
                        } label: {
                            Label(font.installStatus == .installing ? "安装中" : "安装", systemImage: "arrow.down.circle")
                        }
                        .disabled(store.isInstalling)
                    }
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
