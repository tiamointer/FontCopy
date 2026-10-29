import AppKit
import FontCopyCore
import SwiftUI
import UniformTypeIdentifiers

/// 以图找字：拖入/粘贴一张图 → 认字（可改）→ 在库里找字形最接近的字体。
struct ImageFontMatchView: View {
    @ObservedObject var store: FontLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var image: NSImage?
    @State private var cgImage: CGImage?
    @State private var recognized: [RecognizedCharacter] = []
    @State private var splitBoxes: [CGRect] = []
    @State private var text = ""
    @State private var isRecognizing = false
    @State private var progress: (done: Int, total: Int)?
    @State private var results: [FontImageMatch] = []
    @State private var writableCount = 0
    @State private var message: String?
    @State private var isDropTargeted = false

    private static let resultLimit = 20

    private var typedCharacters: [Character] {
        Array(text.filter { !$0.isWhitespace })
    }

    private var usesRecognizedBoxes: Bool {
        !recognized.isEmpty && typedCharacters.count == recognized.count
    }

    /// 第 N 个字 ↔ 第 N 个框。字数和认出的一样就用认字的框，
    /// 否则（没认出、或改了字数）把图按字数平均切开。
    private var pairs: [RecognizedCharacter] {
        let boxes = usesRecognizedBoxes ? recognized.map(\.box) : splitBoxes
        return zip(typedCharacters, boxes).map { RecognizedCharacter(character: $0, box: $1) }
    }

    private var sampleText: String {
        String(pairs.map(\.character))
    }

    private var canStart: Bool {
        !pairs.isEmpty && progress == nil && !store.fonts.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)

            Divider()

            HStack(spacing: 0) {
                inputColumn
                    .frame(width: 380)
                    .background(.background.secondary)

                Divider()

                resultColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("以图找字")
                    .font(.title2.weight(.semibold))
                Text("在库里 \(store.fonts.filter(\.isSupportedFontFile).count) 个字体中，找字形最接近图片的")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pasteImage()
            } label: {
                Label("粘贴图片", systemImage: "doc.on.clipboard")
            }
            Button {
                chooseImage()
            } label: {
                Label("选择图片…", systemImage: "photo")
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 左栏：图片 → 文字 → 开始

    private var inputColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                step(1, "放入图片") {
                    dropZone
                }

                step(2, "确认图里的字") {
                    characterEditor
                }

                step(3, "找字体") {
                    startControl
                }
            }
            .padding(20)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.headline)
            }
            content()
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(image == nil ? 0.35 : 0.15),
                              style: StrokeStyle(lineWidth: 1.5, dash: image == nil ? [6, 4] : []))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay { boxOverlay }
                    .padding(10)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tint)
                    Text("把截图拖到这里")
                        .font(.callout.weight(.medium))
                    Text("或点右上角“粘贴图片”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 200)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var boxOverlay: some View {
        GeometryReader { geometry in
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, item in
                let rect = CGRect(
                    x: item.box.minX * geometry.size.width,
                    y: (1 - item.box.maxY) * geometry.size.height,
                    width: item.box.width * geometry.size.width,
                    height: item.box.height * geometry.size.height
                )
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 2))
                            .offset(x: -1, y: -12)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private var characterEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(isRecognizing ? "认字中…" : "照图把字打进来", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .disabled(image == nil)
                .onChange(of: text) { _, _ in updateSplitBoxes() }
                .onSubmit { if canStart { startMatching() } }

            if !pairs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { index, item in
                            characterChip(index: index, item: item)
                        }
                    }
                }
            }

            Label(boxHint, systemImage: usesRecognizedBoxes ? "checkmark.circle" : "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var boxHint: String {
        if image == nil { return "放入图片后会自动认字" }
        if isRecognizing { return "正在认字…" }
        if usesRecognizedBoxes {
            return "自动认出 \(recognized.count) 个字。认错了就直接改字，字数别变"
        }
        if typedCharacters.isEmpty {
            return "没认出字（手写或图太小时常见）。照图把字打进上面的框"
        }
        return "按你打的 \(typedCharacters.count) 个字，把图平均切成了 \(pairs.count) 份。看看框有没有对准"
    }

    /// 每个框切下来的小图 + 对应的字，方便核对第几个框对第几个字。
    private func characterChip(index: Int, item: RecognizedCharacter) -> some View {
        VStack(spacing: 4) {
            Group {
                if let crop = crop(item.box) {
                    Image(nsImage: crop)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text("\(index + 1) · \(String(item.character))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var startControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("比对中 \(progress.done) / \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    startMatching()
                } label: {
                    Label("在库里找最像的字体", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 右栏：结果

    @ViewBuilder
    private var resultColumn: some View {
        if results.isEmpty {
            ContentUnavailableView {
                Label(progress == nil ? "还没有结果" : "正在比对…", systemImage: "textformat.alt")
            } description: {
                Text("放入一张有字的图片，确认认出的字，然后开始找。\n字越清楚、越大、字数越多，结果越准。")
            }
        } else {
            VStack(spacing: 0) {
                sourceStrip
                Divider()
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { rank, match in
                            ResultCard(
                                rank: rank + 1,
                                match: match,
                                sample: sampleText,
                                isFavorite: isFavorite(match.font),
                                onFavorite: { store.toggleFavorite(match.font) },
                                onReveal: {
                                    store.selectFont(match.font)
                                    dismiss()
                                }
                            )
                        }
                        Text("共 \(writableCount) 个字体写得出这几个字，只列出最像的 \(results.count) 个")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    .padding(16)
                }
            }
        }
    }

    /// 结果顶上固定一条原图，往下滚也能对照。
    private var sourceStrip: some View {
        HStack(spacing: 14) {
            Text("原图")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func isFavorite(_ font: FontItem) -> Bool {
        store.fonts.first { $0.id == font.id }?.isFavorite ?? font.isFavorite
    }

    // MARK: - 载入图片

    private func pasteImage() {
        guard let pasted = NSImage(pasteboard: .general) else {
            message = "剪贴板里没有图片"
            return
        }
        load(pasted)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let picked = NSImage(contentsOf: url) else { return }
        load(picked)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? item as? URL
                guard let url, let dropped = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { load(dropped) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data, let dropped = NSImage(data: data) else { return }
            DispatchQueue.main.async { load(dropped) }
        }
        return true
    }

    private func load(_ newImage: NSImage) {
        guard let cg = newImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            message = "读不了这张图"
            return
        }
        image = newImage
        cgImage = cg
        recognized = []
        splitBoxes = []
        text = ""
        results = []
        message = nil
        isRecognizing = true
        Task.detached(priority: .userInitiated) {
            let found = (try? FontImageMatcher.recognize(cg)) ?? []
            await MainActor.run {
                isRecognizing = false
                recognized = found
                text = String(found.map(\.character))
            }
        }
    }

    private func updateSplitBoxes() {
        let count = typedCharacters.count
        guard let cgImage, count != recognized.count else { return }
        if splitBoxes.count != count {
            splitBoxes = FontImageMatcher.evenBoxes(in: cgImage, count: count)
        }
    }

    private func crop(_ box: CGRect) -> NSImage? {
        guard let cgImage else { return nil }
        let width = Double(cgImage.width)
        let height = Double(cgImage.height)
        let rect = CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        ).insetBy(dx: -box.width * width * 0.08, dy: -box.height * height * 0.08)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let piece = cgImage.cropping(to: rect.integral) else { return nil }
        return NSImage(cgImage: piece, size: NSSize(width: piece.width, height: piece.height))
    }

    // MARK: - 比对

    private func startMatching() {
        guard let cgImage, canStart else { return }
        let characters = pairs
        let fonts = store.fonts.filter { $0.isSupportedFontFile }
        results = []
        message = nil
        progress = (0, fonts.count)

        Task.detached(priority: .userInitiated) {
            let targets = FontImageMatcher.targets(from: cgImage, characters: characters)
            let ranked = FontImageMatcher.rank(targets: targets, fonts: fonts) { done, total in
                if done % 20 == 0 || done == total {
                    Task { @MainActor in progress = (done, total) }
                }
            }
            await MainActor.run {
                progress = nil
                results = Array(ranked.prefix(Self.resultLimit))
                writableCount = ranked.count
                var notes: [String] = []
                if targets.count < characters.count {
                    notes.append("有 \(characters.count - targets.count) 个字没切出来，只用了 \(targets.count) 个字比对")
                }
                if ranked.isEmpty {
                    notes.append("库里没有能写出这几个字的字体")
                }
                message = notes.isEmpty ? nil : notes.joined(separator: "；")
            }
        }
    }
}

/// 一条结果：用该字体写出同样的字，配相似度和操作。第 1 名放大突出。
private struct ResultCard: View {
    let rank: Int
    let match: FontImageMatch
    let sample: String
    let isFavorite: Bool
    let onFavorite: () -> Void
    let onReveal: () -> Void

    @State private var isHovering = false

    private var isBest: Bool { rank == 1 }

    /// 倒角距离换成直观的相似度：0 → 100%，距离 1 像素约 67%。
    private var similarity: Double {
        exp(-match.score / 2.5)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("\(rank)")
                .font(isBest ? .title.weight(.semibold) : .title3)
                .monospacedDigit()
                .foregroundStyle(isBest ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 8) {
                Text(sample)
                    .font(Font(PreviewFontLoader.font(
                        postScriptName: match.font.postScriptName,
                        sourceURL: match.font.sourceURL,
                        size: isBest ? 56 : 38
                    )))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                HStack(spacing: 8) {
                    if isBest {
                        Text("最像")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                    Text(match.font.displayName)
                        .font(.callout.weight(.medium))
                    Text(match.font.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    if match.font.installStatus == .installed {
                        Label("已安装", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int((similarity * 100).rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                ProgressView(value: similarity)
                    .frame(width: 80)
                    .tint(similarity > 0.8 ? .green : similarity > 0.6 ? .accentColor : .orange)
                Text("相似度")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Button(action: onReveal) {
                    Text("在库里查看")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(action: onFavorite) {
                    Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .frame(width: 92)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isBest ? 16 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isBest ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isBest ? 1.5 : 1)
        )
        .onHover { isHovering = $0 }
    }
}
