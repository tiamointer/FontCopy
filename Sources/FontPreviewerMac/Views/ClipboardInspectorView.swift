import FontPreviewerCore
import SwiftUI

struct ClipboardInspectorView: View {
    @ObservedObject var store: FontLibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("剪贴板分析器")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("从 Final Cut Pro 复制标题文本后打开此窗口，可以解析剪贴板里的 RTF/HTML 字体信息。")
                        .foregroundStyle(.secondary)

                    if let analysis = store.clipboardAnalysis {
                        detectedFonts(analysis.fonts)
                        clipboardBlock(title: "RTF 内容", value: analysis.rtf)
                        clipboardBlock(title: "HTML 内容", value: analysis.html)
                        clipboardBlock(title: "纯文本内容", value: analysis.plainText)
                    } else {
                        ContentUnavailableView("没有剪贴板内容", systemImage: "doc.on.clipboard")
                    }
                }
                .padding()
            }
        }
    }

    private func detectedFonts(_ fonts: [ClipboardFontMatch]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分析出的字体")
                .font(.headline)

            if fonts.isEmpty {
                Text("未从剪贴板中解析到字体名称。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fonts) { match in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.name)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Text("来自 \(match.source.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if store.fonts.contains(where: {
                            $0.postScriptName.localizedCaseInsensitiveContains(match.name)
                            || $0.familyName.localizedCaseInsensitiveContains(match.name)
                            || $0.displayName.localizedCaseInsensitiveContains(match.name)
                        }) {
                            Button("在列表中查看") {
                                store.focusAnalyzedFont(named: match.name)
                            }
                        } else {
                            Text("未在库中找到")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func clipboardBlock(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value?.isEmpty == false ? value! : "无内容")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
