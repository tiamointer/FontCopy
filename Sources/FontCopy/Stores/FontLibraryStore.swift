import AppKit
import FontCopyCore
import Foundation

@MainActor
final class FontLibraryStore: ObservableObject {
    enum LibraryMode: Hashable {
        case all
        case favorites
        case category(String)
        case status(FontInstallStatus)
        case selectedFont(UUID)
    }

    @Published var fonts: [FontItem] = []
    @Published var skippedFiles: [SkippedFontFile] = []
    @Published var libraryMode: LibraryMode = .all
    @Published var selectedFontID: UUID?
    @Published var searchText = ""
    @Published var isScanning = false
    @Published var isInstalling = false
    @Published var scanProgress: FontScanProgress?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var clipboardAnalysis: ClipboardAnalysis?
    @Published var isClipboardInspectorPresented = false

    @Published var previewText: String {
        didSet { defaults.set(previewText, forKey: Keys.previewText) }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    private let defaults = UserDefaults.standard
    private let scanner = FontScannerService()
    private let installer = FontInstallService()
    private let pasteboard = PasteboardService()
    private var favoritePostScriptNames: Set<String>
    private var comparedPostScriptNames: Set<String>
    private var lastImportedFolder: URL?
    private var didAttemptSessionRestore = false
    private var activeScanID: UUID?

    init() {
        previewText = defaults.string(forKey: Keys.previewText) ?? "一石二鸟 2 birds 1 stone"
        let storedSize = defaults.double(forKey: Keys.fontSize)
        fontSize = storedSize == 0 ? 50 : storedSize
        favoritePostScriptNames = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        comparedPostScriptNames = Set(defaults.stringArray(forKey: Keys.compared) ?? [])
        if let path = defaults.string(forKey: Keys.lastFolder) {
            lastImportedFolder = URL(fileURLWithPath: path)
        }
    }

    var installedCount: Int {
        fonts.filter { $0.installStatus == .installed }.count
    }

    var missingCount: Int {
        fonts.filter { $0.installStatus == .missing }.count
    }

    var conflictCount: Int {
        fonts.filter { $0.installStatus == .conflict }.count
    }

    var unsupportedCount: Int {
        fonts.filter { $0.installStatus == .unsupported }.count
    }

    var comparedFonts: [FontItem] {
        fonts.filter(\.isCompared)
    }

    var installableFonts: [FontItem] {
        fonts.filter { $0.installStatus.isInstallable && $0.isSupportedFontFile }
    }

    var canRescan: Bool {
        !isScanning && (lastImportedFolder != nil || !fonts.isEmpty)
    }

    var scanProgressFraction: Double {
        scanProgress?.fractionCompleted ?? 0
    }

    var scanProgressText: String {
        scanProgress?.displayText ?? "扫描字体中..."
    }

    var categories: [(String, Int)] {
        let grouped = Dictionary(grouping: filteredBySearch(fonts), by: \.category)
        return grouped
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var visibleFonts: [FontItem] {
        let source: [FontItem]
        switch libraryMode {
        case .all:
            source = fonts
        case .favorites:
            source = fonts.filter(\.isFavorite)
        case .category(let category):
            source = fonts.filter { $0.category == category }
        case .status(let status):
            source = fonts.filter { $0.installStatus == status }
        case .selectedFont(let id):
            source = fonts.filter { $0.id == id }
        }
        return filteredBySearch(source)
    }

    var detailTitle: String {
        switch libraryMode {
        case .all:
            return "所有字体"
        case .favorites:
            return "收藏夹"
        case .category(let category):
            return category
        case .status(let status):
            return status.displayName
        case .selectedFont:
            return selectedFont?.displayName ?? "字体详情"
        }
    }

    var selectedFont: FontItem? {
        guard let selectedFontID else { return nil }
        return fonts.first { $0.id == selectedFontID }
    }

    var isShowingSelectedFontDetail: Bool {
        if case .selectedFont = libraryMode {
            return true
        }
        return false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入字体文件夹"
        panel.message = "选择包含字体文件的文件夹"
        if let lastImportedFolder {
            panel.directoryURL = lastImportedFolder
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await scanFolder(url)
        }
    }

    func rescan() {
        guard let lastImportedFolder else {
            chooseFolder()
            return
        }
        Task {
            await scanFolder(lastImportedFolder)
        }
    }

    func restoreLastFolderIfAvailable() async {
        guard !didAttemptSessionRestore else { return }
        didAttemptSessionRestore = true
        guard fonts.isEmpty, let lastImportedFolder else { return }

        guard FileManager.default.fileExists(atPath: lastImportedFolder.path) else {
            statusMessage = "上次字体文件夹不可访问，请重新导入。"
            return
        }

        await scanFolder(lastImportedFolder, reason: "正在恢复上次字体文件夹")
    }

    func scanFolder(_ url: URL, reason: String = "扫描字体中") async {
        isScanning = true
        errorMessage = nil
        scanProgress = FontScanProgress(processed: 0, total: 0, currentPath: nil)
        statusMessage = reason
        lastImportedFolder = url
        defaults.set(url.path, forKey: Keys.lastFolder)
        let scanID = UUID()
        activeScanID = scanID

        do {
            let favorites = favoritePostScriptNames
            let compared = comparedPostScriptNames
            let scanner = scanner
            let progressBridge = ScanProgressBridge { [weak self] progress in
                guard let self else { return }
                guard self.activeScanID == scanID else { return }
                self.scanProgress = progress
                self.statusMessage = progress.displayText
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try scanner.scanFolder(
                    at: url,
                    favorites: favorites,
                    compared: compared,
                    progress: progressBridge.report
                )
            }.value

            fonts = result.fonts
            skippedFiles = result.skipped
            activeScanID = nil
            scanProgress = nil
            statusMessage = "已加载 \(result.fonts.count) 个字体"
            if selectedFontID == nil {
                selectedFontID = result.fonts.first?.id
            }
            reconcileSelection()
        } catch {
            activeScanID = nil
            scanProgress = nil
            errorMessage = error.localizedDescription
            statusMessage = "扫描失败：\(error.localizedDescription)"
        }

        isScanning = false
    }

    func selectFont(_ font: FontItem) {
        selectedFontID = font.id
        libraryMode = .selectedFont(font.id)
    }

    func showAllFonts() {
        libraryMode = .all
    }

    func setMode(_ mode: LibraryMode) {
        libraryMode = mode
        if case .selectedFont(let id) = mode {
            selectedFontID = id
        }
    }

    func toggleFavorite(_ font: FontItem) {
        statusMessage = nil
        if favoritePostScriptNames.contains(font.postScriptName) {
            favoritePostScriptNames.remove(font.postScriptName)
        } else {
            favoritePostScriptNames.insert(font.postScriptName)
        }
        persistStringSet(favoritePostScriptNames, key: Keys.favorites)
        updateFont(font.id) { $0.isFavorite = favoritePostScriptNames.contains($0.postScriptName) }
    }

    func toggleCompare(_ font: FontItem) {
        statusMessage = nil
        if comparedPostScriptNames.contains(font.postScriptName) {
            comparedPostScriptNames.remove(font.postScriptName)
        } else {
            if comparedPostScriptNames.count >= 9 {
                errorMessage = "最多可以比较 9 种字体。"
                return
            }
            comparedPostScriptNames.insert(font.postScriptName)
        }
        persistStringSet(comparedPostScriptNames, key: Keys.compared)
        updateFont(font.id) { $0.isCompared = comparedPostScriptNames.contains($0.postScriptName) }
    }

    func clearComparison() {
        comparedPostScriptNames.removeAll()
        persistStringSet(comparedPostScriptNames, key: Keys.compared)
        for index in fonts.indices {
            fonts[index].isCompared = false
        }
    }

    func install(_ font: FontItem) {
        guard font.isSupportedFontFile else {
            statusMessage = "「\(font.displayName)」不是 macOS 可直接安装的字体格式。"
            return
        }
        guard font.installStatus.isInstallable else {
            statusMessage = "「\(font.displayName)」当前状态为“\(font.installStatus.displayName)”，不需要单独安装。"
            return
        }

        statusMessage = "准备安装「\(font.displayName)」..."
        Task {
            await installFonts([font], label: "「\(font.displayName)」")
        }
    }

    func installAllMissing() {
        let targets = installableFonts
        guard !targets.isEmpty else {
            statusMessage = "没有可安装的缺失字体。"
            return
        }

        let fileCount = Set(targets.map(\.fileID)).count
        statusMessage = "准备批量安装 \(fileCount) 个字体文件..."
        Task {
            await installFonts(targets, label: "\(fileCount) 个字体文件")
        }
    }

    func copyFCPXStyle(_ font: FontItem, text selectedText: String? = nil) {
        let text = selectedText.flatMap { $0.isEmpty ? nil : $0 } ?? previewText
        pasteboard.copyRichTextForFCPX(text: text, font: font, fontSize: fontSize)
    }

    func presentClipboardInspector() {
        clipboardAnalysis = pasteboard.analyzeClipboard()
        isClipboardInspectorPresented = true
    }

    func focusAnalyzedFont(named name: String) {
        let normalized = name.lowercased()
        if let font = fonts.first(where: {
            $0.postScriptName.lowercased().contains(normalized)
            || $0.familyName.lowercased().contains(normalized)
            || $0.displayName.lowercased().contains(normalized)
        }) {
            selectFont(font)
            searchText = name
            isClipboardInspectorPresented = false
        }
    }

    private func installFonts(_ targetFonts: [FontItem], label: String) async {
        let uniqueFileIDs = Set(targetFonts.map(\.fileID))
        guard !uniqueFileIDs.isEmpty else { return }
        isInstalling = true
        errorMessage = nil
        statusMessage = "正在请求管理员授权安装 \(label)..."

        for index in fonts.indices where uniqueFileIDs.contains(fonts[index].fileID) && fonts[index].installStatus.isInstallable {
            fonts[index].installStatus = .installing
            fonts[index].installError = nil
        }

        let installer = installer
        let result = await Task.detached(priority: .userInitiated) {
            installer.installFonts(targetFonts)
        }.value

        let installedSnapshot = await Task.detached(priority: .userInitiated) {
            InstalledFontService().snapshot()
        }.value

        for index in fonts.indices where uniqueFileIDs.contains(fonts[index].fileID) {
            if let failure = result.failed[fonts[index].fileID] {
                fonts[index].installStatus = .error
                fonts[index].installError = failure
            } else if result.installedFileIDs.contains(fonts[index].fileID) {
                fonts[index].installStatus = .installed
                fonts[index].installError = nil
            } else if installedSnapshot.postScriptNames.contains(fonts[index].postScriptName) {
                fonts[index].installStatus = .installed
                fonts[index].installError = nil
            } else if fonts[index].isSupportedFontFile {
                fonts[index].installStatus = .missing
            }
        }

        if !result.failed.isEmpty {
            let message = result.failed.values.first ?? "安装失败"
            statusMessage = "安装失败：\(message)"
            errorMessage = message
        } else if !result.installedFileIDs.isEmpty {
            statusMessage = "已安装 \(result.installedFileIDs.count) 个字体文件。"
        } else if !result.skippedFileIDs.isEmpty {
            statusMessage = "没有字体需要安装。"
        }
        isInstalling = false
    }

    private func filteredBySearch(_ source: [FontItem]) -> [FontItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }
        let query = trimmed.lowercased()
        return source.filter {
            $0.displayName.lowercased().contains(query)
            || $0.familyName.lowercased().contains(query)
            || $0.postScriptName.lowercased().contains(query)
            || $0.relativePath.lowercased().contains(query)
        }
    }

    private func updateFont(_ id: UUID, mutate: (inout FontItem) -> Void) {
        guard let index = fonts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&fonts[index])
    }

    private func reconcileSelection() {
        if let selectedFontID, fonts.contains(where: { $0.id == selectedFontID }) {
            return
        }
        selectedFontID = fonts.first?.id
        libraryMode = .all
    }

    private func persistStringSet(_ set: Set<String>, key: String) {
        defaults.set(Array(set).sorted(), forKey: key)
    }
}

private enum Keys {
    static let previewText = "preview-text"
    static let fontSize = "font-size"
    static let favorites = "favorite-postscript-names"
    static let compared = "compared-postscript-names"
    static let lastFolder = "last-imported-folder"
}

private final class ScanProgressBridge: @unchecked Sendable {
    private let update: @MainActor (FontScanProgress) -> Void

    init(update: @escaping @MainActor (FontScanProgress) -> Void) {
        self.update = update
    }

    func report(_ progress: FontScanProgress) {
        Task { @MainActor in
            update(progress)
        }
    }
}
