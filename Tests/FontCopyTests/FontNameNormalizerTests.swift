import FontCopyCore
import CoreText
import Foundation
import Testing

@Test func normalizesTTFFontNameAndCreatesBackup() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let fontURL = tempDirectory.appendingPathComponent("测试字体名称.ttf")
    try FileManager.default.copyItem(at: try systemTTFFont(), to: fontURL)

    let result = FontNameNormalizerService().normalizeFile(at: fontURL)

    #expect(result.status == .success)
    #expect(result.targetName == "测试字体名称")
    #expect(result.postScriptName?.hasPrefix("FontCopy-") == true)
    #expect(result.backupURL != nil)
    #expect(FileManager.default.fileExists(atPath: result.backupURL?.path ?? "") == true)

    let metadata = FontMetadataReader.metadata(for: fontURL)
    #expect(metadata.contains { $0.familyName == "测试字体名称" })
    #expect(metadata.contains { $0.displayName == "测试字体名称" })
    #expect(metadata.contains { $0.postScriptName == result.postScriptName })
}

@Test func backupNamesIncrementWhenBakAlreadyExists() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let fontURL = tempDirectory.appendingPathComponent("重复备份.ttf")
    let existingBackupURL = URL(fileURLWithPath: fontURL.path + ".bak")
    try FileManager.default.copyItem(at: try systemTTFFont(), to: fontURL)
    try Data("existing".utf8).write(to: existingBackupURL)

    let result = FontNameNormalizerService().normalizeFile(at: fontURL)

    #expect(result.status == .success)
    #expect(result.backupURL?.lastPathComponent == "重复备份.ttf.bak-2")
    #expect(FileManager.default.fileExists(atPath: existingBackupURL.path) == true)
    #expect(FileManager.default.fileExists(atPath: result.backupURL?.path ?? "") == true)
}

@Test func skipsFontCollectionsForFirstVersion() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let collectionURL = tempDirectory.appendingPathComponent("集合字体.ttc")
    try Data("ttcf".utf8).write(to: collectionURL)

    let result = FontNameNormalizerService().normalizeFile(at: collectionURL)

    #expect(result.status == .skipped)
    #expect(result.message.contains("暂不支持"))
}

@Test func normalizerSkipsBackupNamedFontFiles() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let backupFontURL = tempDirectory.appendingPathComponent("备份文件.bak.ttf")
    try FileManager.default.copyItem(at: try systemTTFFont(), to: backupFontURL)

    let result = FontNameNormalizerService().normalizeFile(at: backupFontURL)

    #expect(result.status == .skipped)
    #expect(result.message.contains("备份"))
    #expect(result.backupURL == nil)
}

@Test func scannerSkipsFontCopyBackupFiles() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let visibleFontURL = tempDirectory.appendingPathComponent("可扫描字体.ttf")
    let legitimateBakNameURL = tempDirectory.appendingPathComponent("Bak.ttf")
    let legitimateBakeryNameURL = tempDirectory.appendingPathComponent("sample.bakery.ttf")
    let backupFontURL = tempDirectory.appendingPathComponent("可扫描字体.bak.ttf")
    try FileManager.default.copyItem(at: try systemTTFFont(), to: visibleFontURL)
    try FileManager.default.copyItem(at: try systemTTFFont(), to: legitimateBakNameURL)
    try FileManager.default.copyItem(at: try systemTTFFont(), to: legitimateBakeryNameURL)
    try FileManager.default.copyItem(at: try systemTTFFont(), to: backupFontURL)

    let result = try FontScannerService().scanFolder(at: tempDirectory, favorites: [], compared: [])

    #expect(result.fonts.contains { $0.sourceURL.lastPathComponent == visibleFontURL.lastPathComponent })
    #expect(result.fonts.contains { $0.sourceURL.lastPathComponent == legitimateBakNameURL.lastPathComponent })
    #expect(result.fonts.contains { $0.sourceURL.lastPathComponent == legitimateBakeryNameURL.lastPathComponent })
    #expect(result.fonts.allSatisfy { !PathUtilities.isFontCopyBackupFile($0.sourceURL) })
}

@Test func processRegisteredPreviewFontDoesNotBecomeInstalled() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let fontURL = tempDirectory.appendingPathComponent("只用于预览的字体.ttf")
    try FileManager.default.copyItem(at: try systemTTFFont(), to: fontURL)
    let normalizeResult = FontNameNormalizerService().normalizeFile(at: fontURL)
    let postScriptName = try #require(normalizeResult.postScriptName)

    var registerError: Unmanaged<CFError>?
    let didRegister = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registerError)
    #expect(didRegister)
    defer {
        var unregisterError: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, &unregisterError)
    }

    let snapshot = InstalledFontService().snapshot()

    #expect(!snapshot.postScriptNames.contains(postScriptName))
}

private func systemTTFFont() throws -> URL {
    let candidates = [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Geneva.ttf",
        "/System/Library/Fonts/SFNS.ttf"
    ]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        throw TestFontError.missingSystemFont
    }
    return URL(fileURLWithPath: path)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FontCopyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum TestFontError: Error {
    case missingSystemFont
}
