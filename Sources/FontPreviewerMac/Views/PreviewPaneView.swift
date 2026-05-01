import FontPreviewerCore
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
                        onCopy: store.copyFCPXStyle,
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

            if store.isInstalling {
                ProgressView()
                    .controlSize(.small)
            }

            Button("清除比较") {
                store.clearComparison()
            }
            .disabled(store.comparedFonts.isEmpty)

            Button("安装全部未安装") {
                store.installAllMissing()
            }
            .disabled(store.installableFonts.isEmpty || store.isInstalling)
        }
    }

    private var summaryText: String {
        "\(store.visibleFonts.count) 个字体 · 未安装 \(store.missingCount) · 冲突 \(store.conflictCount) · 不支持 \(store.unsupportedCount)"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "textformat")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("欢迎使用字体预览器")
                .font(.title2.weight(.semibold))
            Text("点击工具栏的“导入文件夹”开始扫描本机字体资产。")
                .foregroundStyle(.secondary)
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
                onCopy: store.copyFCPXStyle,
                onSelect: store.selectFont
            )
            .frame(height: 220)
        }
    }
}
