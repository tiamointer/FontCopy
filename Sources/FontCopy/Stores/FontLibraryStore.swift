import AppKit
import FontCopyCore
import Foundation
import UniformTypeIdentifiers

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
    @Published var libraryMode: LibraryMode = .all {
        didSet {
            if libraryMode != oldValue {
                statusMessage = nil
            }
        }
    }
    @Published var selectedFontID: UUID?
    @Published var searchText = ""
    @Published var isScanning = false
    @Published var isInstalling = false
    @Published var isNormalizingFontNames = false
    @Published var isImportingDrop = false
    @Published var scanProgress: FontScanProgress?
    @Published var normalizeProgress: FontNormalizeProgress?
    @Published var installProgress: FontInstallProgress?
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

    @Published var isCompatibilityModeEnabled: Bool {
        didSet { defaults.set(isCompatibilityModeEnabled, forKey: Keys.compatibilityEnabled) }
    }

    @Published var isApplyingCompatibility = false
    @Published var compatibilityFontCount = 0

    private let defaults = UserDefaults.standard
    private let scanner = FontScannerService()
    private let installer = FontInstallService()
    private let nameNormalizer = FontNameNormalizerService()
    private let scanCache = FontScanCache()
    private let pasteboard = PasteboardService()
    private let importer = FontImportService()
    private let compatibilityService = CompatibilityFontService()
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
        isCompatibilityModeEnabled = defaults.bool(forKey: Keys.compatibilityEnabled)
        if let path = defaults.string(forKey: Keys.lastFolder) {
            lastImportedFolder = URL(fileURLWithPath: path)
        }
        if isCompatibilityModeEnabled {
            compatibilityFontCount = compatibilityService.installedCount()
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
        visibleFonts.filter { $0.installStatus.isInstallable && $0.isSupportedFontFile }
    }

    var visibleMissingCount: Int {
        visibleFonts.filter { $0.installStatus == .missing }.count
    }

    var visibleConflictCount: Int {
        visibleFonts.filter { $0.installStatus == .conflict }.count
    }

    var visibleUnsupportedCount: Int {
        visibleFonts.filter { $0.installStatus == .unsupported }.count
    }

    var visibleInstalledCount: Int {
        visibleFonts.filter { $0.installStatus == .installed }.count
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
            await scanFolder(lastImportedFolder, forceFullRescan: true)
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

    func scanFolder(_ url: URL, reason: String = "扫描字体中", forceFullRescan: Bool = false) async {
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
            let cached = scanCache.load(forRoot: url)
            let cache = scanCache
            let partialBridge = ScanPartialBridge { [weak self] partial in
                guard let self, self.activeScanID == scanID else { return }
                self.fonts = partial
                self.scanProgress = nil
                self.statusMessage = "已加载 \(partial.count) 个字体，正在核对安装状态…"
                if self.selectedFontID == nil {
                    self.selectedFontID = partial.first?.id
                }
            }
            let result = try await Task.detached(priority: .userInitiated) {
                let r = try scanner.scanFolder(
                    at: url,
                    favorites: favorites,
                    compared: compared,
                    cachedEntries: cached,
                    forceFullRescan: forceFullRescan,
                    progress: progressBridge.report,
                    onPartial: partialBridge.report
                )
                cache.save(forRoot: url, entries: r.cacheEntries)
                return r
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

    func confirmAndInstallAllMissing() {
        let targets = installableFonts
        guard !targets.isEmpty else {
            statusMessage = "没有可安装的缺失字体。"
            return
        }

        let fileCount = Set(targets.map(\.fileID)).count
        statusMessage = "正在检测系统中是否存在旧版本..."

        Task {
            let priorMatches = await detectPriorInstalledMatches(for: targets)
            let decision = await MainActor.run {
                presentInstallConfirmation(
                    fileCount: fileCount,
                    fontCount: targets.count,
                    priorMatches: priorMatches
                )
            }
            switch decision {
            case .cancel:
                statusMessage = nil
                return
            case .keepOld:
                statusMessage = "准备批量安装 \(fileCount) 个字体文件..."
                await installFonts(targets, label: "\(fileCount) 个字体文件", removingURLs: [])
            case .replaceOld:
                let removalURLs = Array(Set(priorMatches.flatMap { $0.removableInstalledURLs }))
                statusMessage = "准备批量安装 \(fileCount) 个并移除 \(removalURLs.count) 个旧版本文件..."
                await installFonts(targets, label: "\(fileCount) 个字体文件", removingURLs: removalURLs)
            }
        }
    }

    nonisolated private func detectPriorInstalledMatches(for fonts: [FontItem]) async -> [PriorInstalledMatch] {
        await Task.detached(priority: .userInitiated) {
            let snapshot = InstalledFontService().snapshot()
            var matches: [PriorInstalledMatch] = []
            var seenSourcePaths = Set<String>()
            for font in fonts {
                let path = font.sourceURL.standardizedFileURL.path
                guard !seenSourcePaths.contains(path) else { continue }
                seenSourcePaths.insert(path)
                guard let prior = PriorFontIdentityResolver.resolve(for: font.sourceURL) else { continue }
                let removableURLs = snapshot.removableInstalledURLs(forPostScriptName: prior.postScriptName)
                guard !removableURLs.isEmpty else { continue }
                matches.append(PriorInstalledMatch(
                    font: font,
                    prior: prior,
                    removableInstalledURLs: removableURLs
                ))
            }
            return matches
        }.value
    }

    func importDroppedFiles(_ urls: [URL], intoCategory category: String?) {
        guard !urls.isEmpty else { return }
        guard let importedRoot = lastImportedFolder else {
            errorMessage = "请先点击工具栏「导入文件夹」选择字体库根目录。"
            return
        }
        guard !isImportingDrop, !isScanning, !isInstalling, !isNormalizingFontNames else {
            statusMessage = "正在处理上一个操作，请稍后再试。"
            return
        }
        let supportedExtensions = FontItem.fontLikeExtensions
        let filteredURLs = urls.filter {
            supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !filteredURLs.isEmpty else {
            statusMessage = "拖入的文件中没有支持的字体格式。"
            return
        }

        Task {
            let resolvedCategory: String
            if let category {
                resolvedCategory = category
            } else if let chosen = presentCategoryPicker(fileCount: filteredURLs.count) {
                resolvedCategory = chosen
            } else {
                statusMessage = nil
                return
            }

            await runDropImport(urls: filteredURLs, category: resolvedCategory, importedRoot: importedRoot)
        }
    }

    private func runDropImport(urls: [URL], category: String, importedRoot: URL) async {
        isImportingDrop = true
        defer { isImportingDrop = false }
        errorMessage = nil
        statusMessage = "正在分析 \(urls.count) 个字体文件..."

        let importer = importer
        let snapshotFonts = fonts
        let evaluations = await Task.detached(priority: .userInitiated) {
            evaluateDroppedFiles(
                urls: urls,
                category: category,
                importedRoot: importedRoot,
                libraryFonts: snapshotFonts,
                importer: importer
            )
        }.value

        let rejections = evaluations.compactMap { (url, result) -> (URL, FontImportRejection)? in
            if case .failure(let rejection) = result { return (url, rejection) }
            return nil
        }
        let successes = evaluations.compactMap { (_, result) -> FontImportEvaluation? in
            if case .success(let evaluation) = result { return evaluation }
            return nil
        }

        if successes.isEmpty {
            statusMessage = "没有可导入的字体。"
            if let firstRejection = rejections.first {
                errorMessage = firstRejection.1.localizedDescription
            }
            return
        }

        let conflicts = successes.filter(\.hasConflict)
        let conflictMode: FontImportPlan.ConflictMode
        if conflicts.isEmpty {
            conflictMode = .skip
        } else {
            switch presentDropConflictResolution(
                evaluations: successes,
                category: category,
                rejectionCount: rejections.count
            ) {
            case .cancel:
                statusMessage = "已取消导入。"
                return
            case .skipConflicts:
                conflictMode = .skip
            case .overwriteAll:
                conflictMode = .overwrite
            }
        }

        let plan = FontImportPlan(evaluations: successes, conflictMode: conflictMode)
        let executable = plan.executableEvaluations
        if executable.isEmpty {
            statusMessage = "没有可导入的字体（全部冲突已跳过）。"
            return
        }

        statusMessage = "正在导入 \(executable.count) 个字体到“\(category)”..."
        let copyOps = plan.copyOperations
        let removalURLs = plan.filesToRemove
        let executionResult = await Task.detached(priority: .userInitiated) {
            performDropImport(removalURLs: removalURLs, copyOperations: copyOps)
        }.value

        if let failure = executionResult.failure {
            errorMessage = failure
            statusMessage = "导入失败：\(failure)"
            return
        }

        await scanFolder(importedRoot, reason: "正在刷新拖入的字体")
        var summary = "已导入 \(executable.count) 个字体到“\(category)”"
        if !removalURLs.isEmpty {
            summary += "，并移除 \(removalURLs.count) 个旧文件"
        }
        if !rejections.isEmpty {
            summary += "（忽略 \(rejections.count) 个无法读取的文件）"
        }
        statusMessage = summary
    }

    private func presentCategoryPicker(fileCount: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = "选择目标分类"
        alert.informativeText = "将 \(fileCount) 个字体文件添加到："

        let availableCategories = categories.map(\.0).sorted()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        for category in availableCategories {
            popup.addItem(withTitle: category)
        }
        popup.addItem(withTitle: "未分类（根目录）")
        if availableCategories.isEmpty {
            popup.selectItem(withTitle: "未分类（根目录）")
        }
        alert.accessoryView = popup
        let confirm = alert.addButton(withTitle: "添加")
        confirm.keyEquivalent = "\r"
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let title = popup.titleOfSelectedItem ?? "未分类（根目录）"
            return title == "未分类（根目录）" ? "未分类" : title
        default:
            return nil
        }
    }

    private func presentDropConflictResolution(
        evaluations: [FontImportEvaluation],
        category: String,
        rejectionCount: Int
    ) -> DropDecision {
        let conflicting = evaluations.filter(\.hasConflict)
        let cleanCount = evaluations.count - conflicting.count

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检测到 \(conflicting.count) 个文件存在冲突"
        let preview = conflicting.prefix(5).map { evaluation -> String in
            let detail = evaluation.conflicts.map(describe).joined(separator: "；")
            return "• \(evaluation.sourceURL.lastPathComponent) → \(evaluation.category)\n    \(detail)"
        }.joined(separator: "\n")
        let extra = conflicting.count > 5 ? "\n…还有 \(conflicting.count - 5) 个" : ""
        var trailing = "\n\n\(cleanCount) 个无冲突文件可直接添加。"
        if rejectionCount > 0 {
            trailing += "\n另有 \(rejectionCount) 个文件无法读取，已自动跳过。"
        }
        alert.informativeText = preview + extra + trailing

        let overwrite = alert.addButton(withTitle: "全部覆盖")
        overwrite.keyEquivalent = "\r"
        alert.addButton(withTitle: "跳过冲突，添加其他")
        let cancel = alert.addButton(withTitle: "取消整个操作")
        cancel.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwriteAll
        case .alertSecondButtonReturn: return .skipConflicts
        default: return .cancel
        }
    }

    private func describe(_ conflict: FontImportConflict) -> String {
        switch conflict {
        case .destinationFilenameCollision(let url):
            return "目标目录已有同名文件：\(url.lastPathComponent)"
        case .sameContentInLibrary(let font):
            return "内容相同的字体已存在：\(font.relativePath)"
        case .samePostScriptInLibrary(let font):
            return "同 PostScript 名字体已存在：\(font.relativePath)"
        }
    }

    func normalizeSingleFontFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = fontFileContentTypes
        panel.prompt = "选择字体文件"
        panel.message = "选择要写入内部名称的字体文件。"
        if let lastImportedFolder {
            panel.directoryURL = lastImportedFolder
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirmFontNameNormalization(targetDescription: url.lastPathComponent) else { return }

        Task {
            await normalizeFontNames(scopeURL: url, mode: .singleFile(url))
        }
    }

    func normalizeFontFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        panel.message = "批量规范化此文件夹内 .ttf/.otf 字体的内部名称。"
        if let lastImportedFolder {
            panel.directoryURL = lastImportedFolder
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirmFontNameNormalization(targetDescription: url.lastPathComponent) else { return }

        Task {
            await normalizeFontNames(scopeURL: url, mode: .folder(url))
        }
    }

    var normalizableVisibleFontFiles: [URL] {
        var seenPaths = Set<String>()
        var urls: [URL] = []
        for font in visibleFonts where font.canNormalizeInternalName {
            let path = font.sourceURL.standardizedFileURL.path
            if seenPaths.insert(path).inserted {
                urls.append(font.sourceURL)
            }
        }
        return urls
    }

    func normalizeVisibleFonts() {
        let urls = normalizableVisibleFontFiles
        guard !urls.isEmpty else {
            statusMessage = "当前可见范围内没有需要规范化的字体（文件名和内部名称已经一致）。"
            return
        }
        guard !isScanning, !isInstalling, !isNormalizingFontNames else { return }
        guard let importedRoot = lastImportedFolder else {
            errorMessage = "请先导入字体文件夹。"
            return
        }
        let scope = currentScopeDescription()
        guard confirmFontNameNormalization(targetDescription: "\(scope)（\(urls.count) 个字体文件）") else { return }

        Task {
            await normalizeFontNames(scopeURL: importedRoot, mode: .files(urls))
        }
    }

    func normalizeFontName(_ font: FontItem) {
        guard font.canNormalizeInternalName else {
            statusMessage = "「\(font.displayName)」的文件名和内部名称已经一致，或当前格式暂不支持规范化。"
            return
        }
        guard confirmFontNameNormalization(targetDescription: font.sourceURL.lastPathComponent) else { return }

        Task {
            await normalizeFontNames(scopeURL: font.sourceURL, mode: .singleFile(font.sourceURL))
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

    func toggleCompatibilityMode() {
        guard !isScanning, !isInstalling, !isNormalizingFontNames, !isApplyingCompatibility else { return }

        if isCompatibilityModeEnabled {
            isApplyingCompatibility = true
            statusMessage = "正在清除兼容字体..."
            let service = compatibilityService
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    service.disable()
                }.value
                isApplyingCompatibility = false
                if result.failed.isEmpty {
                    compatibilityFontCount = 0
                    isCompatibilityModeEnabled = false
                    statusMessage = "已清除兼容字体。"
                } else {
                    compatibilityFontCount = result.installedCount
                    statusMessage = "清除未完成，仍残留 \(result.installedCount) 个兼容字体。"
                    errorMessage = "清除兼容字体失败：\(result.failed.values.first ?? "未知错误")"
                }
            }
            return
        }

        guard let scanRoot = lastImportedFolder else {
            errorMessage = "请先导入字体文件夹。"
            return
        }

        isApplyingCompatibility = true
        errorMessage = nil
        statusMessage = "正在安装兼容字体..."
        let service = compatibilityService
        let progressBridge = CompatibilityProgressBridge { [weak self] progress in
            self?.statusMessage = "正在安装兼容字体 \(progress.processed)/\(progress.total)..."
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                service.enable(scanRoot: scanRoot, progress: progressBridge.report)
            }.value
            compatibilityFontCount = result.installedCount
            isApplyingCompatibility = false

            if result.installedCount == 0 && result.failed.isEmpty {
                statusMessage = "未找到任何备份字体（.bak），无需开启兼容模式。"
            } else {
                isCompatibilityModeEnabled = true
                if result.failed.isEmpty {
                    statusMessage = "已临时安装 \(result.installedCount) 个兼容字体。"
                } else {
                    statusMessage = "已临时安装 \(result.installedCount) 个兼容字体，\(result.failed.count) 个失败。"
                    errorMessage = result.failed.values.first
                }
            }
        }
    }

    private func installFonts(_ targetFonts: [FontItem], label: String, removingURLs: [URL] = []) async {
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
        let urlsToRemove = removingURLs
        installProgress = FontInstallProgress(phase: .staging, processed: 0, total: targetFonts.count, currentName: nil)
        let installProgressBridge = InstallProgressBridge { [weak self] progress in
            self?.installProgress = progress
        }
        let result = await Task.detached(priority: .userInitiated) {
            installer.installFonts(targetFonts, removingURLs: urlsToRemove, progress: installProgressBridge.report)
        }.value
        installProgress = nil

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
            if result.removedURLs.isEmpty {
                statusMessage = "已安装 \(result.installedFileIDs.count) 个字体文件。"
            } else {
                statusMessage = "已安装 \(result.installedFileIDs.count) 个字体文件，并移除 \(result.removedURLs.count) 个旧版本。"
            }
        } else if !result.skippedFileIDs.isEmpty {
            statusMessage = "没有字体需要安装。"
        }
        isInstalling = false
    }

    private enum FontNameNormalizationMode: Sendable {
        case singleFile(URL)
        case folder(URL)
        case files([URL])
    }

    private func normalizeFontNames(scopeURL: URL, mode: FontNameNormalizationMode) async {
        isNormalizingFontNames = true
        errorMessage = nil
        statusMessage = "正在规范化字体名称..."

        let normalizer = nameNormalizer
        let normalizeBridge = NormalizeProgressBridge { [weak self] progress in
            self?.normalizeProgress = progress
        }
        normalizeProgress = nil
        let report = await Task.detached(priority: .userInitiated) {
            switch mode {
            case .singleFile(let url):
                return FontNameNormalizationReport(results: [normalizer.normalizeFile(at: url)])
            case .folder(let url):
                return normalizer.normalizeFolder(at: url, progress: normalizeBridge.report)
            case .files(let urls):
                return normalizer.normalizeFiles(urls, progress: normalizeBridge.report)
            }
        }.value

        normalizeProgress = nil
        isNormalizingFontNames = false
        statusMessage = report.summary
        if report.failedCount > 0 || report.skippedCount > 0 {
            errorMessage = report.detailMessage
        }

        if report.successCount > 0, shouldRescanAfterNormalization(scopeURL: scopeURL), let lastImportedFolder {
            await scanFolder(lastImportedFolder, reason: "正在刷新改名后的字体")
            statusMessage = "\(report.summary)，已刷新字体库"
        }
    }

    private func confirmFontNameNormalization(targetDescription: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "规范化字体名称"
        alert.informativeText = """
        这不会安装字体。

        FontCopy 会根据文件名改写字体内部名称，并在同级目录创建 .bak 备份。

        目标：\(targetDescription)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "继续")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func presentInstallConfirmation(
        fileCount: Int,
        fontCount: Int,
        priorMatches: [PriorInstalledMatch]
    ) -> InstallDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let scopeDescription = currentScopeDescription()

        if priorMatches.isEmpty {
            alert.messageText = "确认安装当前未安装字体？"
            alert.informativeText = """
            范围：\(scopeDescription)

            这会把 \(fileCount) 个字体文件安装到 /Library/Fonts，并需要管理员授权。

            如果你还需要先“规范化字体名称”，请取消并先使用侧边栏“工具”里的规范化功能。

            涉及字体条目：\(fontCount)
            """
            let install = alert.addButton(withTitle: "确认安装")
            install.keyEquivalent = "\r"
            let cancel = alert.addButton(withTitle: "取消")
            cancel.keyEquivalent = "\u{1b}"

            switch alert.runModal() {
            case .alertFirstButtonReturn: return .keepOld
            default: return .cancel
            }
        }

        let removalCount = Set(priorMatches.flatMap { $0.removableInstalledURLs }).count
        alert.messageText = "检测到 \(priorMatches.count) 个字体在系统中存在旧版本"
        let preview = priorMatches.prefix(5).map { match in
            let oldFile = match.removableInstalledURLs.first?.lastPathComponent ?? "未知"
            return "• \(match.font.displayName)  ← \(oldFile)（旧 PostScript：\(match.prior.postScriptName)）"
        }.joined(separator: "\n")
        let extra = priorMatches.count > 5 ? "\n…还有 \(priorMatches.count - 5) 个" : ""
        alert.informativeText = """
        范围：\(scopeDescription)

        这次会把 \(fileCount) 个字体文件安装到 /Library/Fonts，需要管理员授权。

        其中 \(priorMatches.count) 个字体被检测到在系统里仍有旧版本（依据是规范化前的 PostScript 名）：
        \(preview)\(extra)

        选择「移除旧版」会在安装时一并删除上述 \(removalCount) 个旧文件，避免字体库重复。
        旧 PostScript 名将不再可用，请确认没有项目仍按旧名引用。
        """
        let replace = alert.addButton(withTitle: "移除旧版并安装")
        replace.keyEquivalent = "\r"
        alert.addButton(withTitle: "只安装新版（保留旧版）")
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replaceOld
        case .alertSecondButtonReturn: return .keepOld
        default: return .cancel
        }
    }

    private func currentScopeDescription() -> String {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseScope: String
        switch libraryMode {
        case .all: baseScope = "所有字体"
        case .favorites: baseScope = "收藏夹"
        case .category(let category): baseScope = "分类 “\(category)”"
        case .status(let status): baseScope = "状态 “\(status.displayName)”"
        case .selectedFont: baseScope = "当前选中字体"
        }
        if trimmedSearch.isEmpty {
            return baseScope
        }
        return "\(baseScope) · 搜索 “\(trimmedSearch)”"
    }

    private func shouldRescanAfterNormalization(scopeURL: URL) -> Bool {
        guard let lastImportedFolder else { return false }
        let scopePath = scopeURL.standardizedFileURL.path
        let libraryPath = lastImportedFolder.standardizedFileURL.path
        if scopePath == libraryPath { return true }
        if scopePath.hasPrefix(libraryPath + "/") { return true }
        if libraryPath.hasPrefix(scopePath + "/") { return true }
        return false
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
    static let compatibilityEnabled = "compatibility-mode-enabled"
}

struct PriorInstalledMatch: Sendable {
    let font: FontItem
    let prior: PriorFontIdentity
    let removableInstalledURLs: [URL]
}

enum InstallDecision {
    case cancel
    case keepOld
    case replaceOld
}

enum DropDecision {
    case cancel
    case skipConflicts
    case overwriteAll
}

private struct DropExecutionResult: Sendable {
    let failure: String?
}

private func evaluateDroppedFiles(
    urls: [URL],
    category: String,
    importedRoot: URL,
    libraryFonts: [FontItem],
    importer: FontImportService
) -> [(URL, Result<FontImportEvaluation, FontImportRejection>)] {
    urls.map { url in
        do {
            let evaluation = try importer.evaluate(
                sourceURL: url,
                intoCategory: category,
                importedRoot: importedRoot,
                libraryFonts: libraryFonts
            )
            return (url, .success(evaluation))
        } catch let rejection as FontImportRejection {
            return (url, .failure(rejection))
        } catch {
            return (url, .failure(.unreadable(url, error.localizedDescription)))
        }
    }
}

private func performDropImport(
    removalURLs: [URL],
    copyOperations: [(source: URL, destination: URL)]
) -> DropExecutionResult {
    let fileManager = FileManager.default
    do {
        for url in removalURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        for operation in copyOperations {
            let destinationFolder = operation.destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: operation.destination.path) {
                try fileManager.removeItem(at: operation.destination)
            }
            try fileManager.copyItem(at: operation.source, to: operation.destination)
        }
    } catch {
        return DropExecutionResult(failure: error.localizedDescription)
    }
    return DropExecutionResult(failure: nil)
}

private let fontFileContentTypes: [UTType] = ["ttf", "otf", "ttc", "otc"].compactMap {
    UTType(filenameExtension: $0)
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

private final class ScanPartialBridge: @unchecked Sendable {
    private let update: @MainActor ([FontItem]) -> Void

    init(update: @escaping @MainActor ([FontItem]) -> Void) {
        self.update = update
    }

    func report(_ fonts: [FontItem]) {
        Task { @MainActor in
            update(fonts)
        }
    }
}

private final class NormalizeProgressBridge: @unchecked Sendable {
    private let update: @MainActor (FontNormalizeProgress) -> Void

    init(update: @escaping @MainActor (FontNormalizeProgress) -> Void) {
        self.update = update
    }

    func report(_ progress: FontNormalizeProgress) {
        Task { @MainActor in
            update(progress)
        }
    }
}

private final class InstallProgressBridge: @unchecked Sendable {
    private let update: @MainActor (FontInstallProgress) -> Void

    init(update: @escaping @MainActor (FontInstallProgress) -> Void) {
        self.update = update
    }

    func report(_ progress: FontInstallProgress) {
        Task { @MainActor in
            update(progress)
        }
    }
}

private final class CompatibilityProgressBridge: @unchecked Sendable {
    private let update: @MainActor (CompatibilityProgress) -> Void

    init(update: @escaping @MainActor (CompatibilityProgress) -> Void) {
        self.update = update
    }

    func report(_ progress: CompatibilityProgress) {
        Task { @MainActor in
            update(progress)
        }
    }
}
