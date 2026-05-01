import FontCopyCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: FontLibraryStore
    @State private var dropTargetCategory: String?
    @State private var dropTargetAllFonts = false

    var body: some View {
        List(selection: Binding(
            get: { store.libraryMode },
            set: { store.setMode($0) }
        )) {
            Section {
                controls
            }

            Section("分类") {
                ForEach(store.categories, id: \.0) { category, count in
                    Label(category, systemImage: "folder")
                        .badge(count)
                        .tag(FontLibraryStore.LibraryMode.category(category))
                        .listRowBackground(dropTargetCategory == category ? Color.accentColor.opacity(0.18) : Color.clear)
                        .onDrop(of: [.fileURL], isTargeted: dropBinding(for: category)) { providers in
                            handleDrop(providers: providers, intoCategory: category)
                        }
                }
            }

            Section("工具") {
                Menu {
                    Button {
                        store.normalizeSingleFontFile()
                    } label: {
                        Label("选择单个字体文件...", systemImage: "doc")
                    }

                    Button {
                        store.normalizeFontFolder()
                    } label: {
                        Label("选择文件夹批量处理...", systemImage: "folder")
                    }
                } label: {
                    Label("规范化字体名称", systemImage: "pencil.and.outline")
                }
                .disabled(store.isScanning || store.isInstalling || store.isNormalizingFontNames)
                .help("只改写字体文件内部名称，不会安装字体")
            }

            Section("库") {
                Label("所有字体", systemImage: "textformat")
                    .badge(store.fonts.count)
                    .tag(FontLibraryStore.LibraryMode.all)
                    .listRowBackground(dropTargetAllFonts ? Color.accentColor.opacity(0.18) : Color.clear)
                    .onDrop(of: [.fileURL], isTargeted: $dropTargetAllFonts) { providers in
                        handleDrop(providers: providers, intoCategory: nil)
                    }

                Label("收藏夹", systemImage: "star")
                    .badge(store.fonts.filter(\.isFavorite).count)
                    .tag(FontLibraryStore.LibraryMode.favorites)
            }

            Section("安装状态") {
                statusRow(.missing, count: store.missingCount)
                statusRow(.installed, count: store.installedCount)
                statusRow(.conflict, count: store.conflictCount)
                statusRow(.unsupported, count: store.unsupportedCount)
            }

            Section("字体") {
                ForEach(store.visibleFonts.prefix(400)) { font in
                    Button {
                        store.selectFont(font)
                    } label: {
                        FontSidebarRow(font: font)
                    }
                    .buttonStyle(.plain)
                    .tag(FontLibraryStore.LibraryMode.selectedFont(font.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索字体...", text: $store.searchText)
                .textFieldStyle(.roundedBorder)

            Text("预览文本")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $store.previewText)
                .font(.body)
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Text("字号")
                    .foregroundStyle(.secondary)
                Slider(value: $store.fontSize, in: 8...200, step: 1)
                Text("\(Int(store.fontSize))")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
    }

    private func statusRow(_ status: FontInstallStatus, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(status))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor(status))
                .frame(width: 16)

            Text(status.displayName)
        }
        .badge(count)
        .tag(FontLibraryStore.LibraryMode.status(status))
    }

    private func statusIcon(_ status: FontInstallStatus) -> String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .missing: return "arrow.down.circle.fill"
        case .unsupported: return "nosign"
        case .conflict: return "exclamationmark.triangle"
        case .installing: return "clock"
        case .error: return "xmark.octagon"
        }
    }

    private func dropBinding(for category: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetCategory == category },
            set: { dropTargetCategory = $0 ? category : nil }
        )
    }

    private func handleDrop(providers: [NSItemProvider], intoCategory category: String?) -> Bool {
        let group = DispatchGroup()
        var collected: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collected.append(url)
                } else if let url = item as? URL {
                    collected.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            store.importDroppedFiles(collected, intoCategory: category)
        }
        return true
    }

    private func statusColor(_ status: FontInstallStatus) -> Color {
        switch status {
        case .installed: return .green
        case .missing: return .orange
        case .unsupported: return .secondary
        case .conflict: return .yellow
        case .installing: return .blue
        case .error: return .red
        }
    }
}

private struct FontSidebarRow: View {
    let font: FontItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(font.displayName)
                    .lineLimit(1)
                Text(font.familyName == font.displayName ? font.relativePath : font.familyName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var icon: String {
        switch font.installStatus {
        case .installed: return "checkmark.circle.fill"
        case .missing: return "arrow.down.circle"
        case .unsupported: return "nosign"
        case .conflict: return "exclamationmark.triangle.fill"
        case .installing: return "clock"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch font.installStatus {
        case .installed: return .green
        case .missing: return .orange
        case .unsupported: return .secondary
        case .conflict: return .yellow
        case .installing: return .blue
        case .error: return .red
        }
    }
}
