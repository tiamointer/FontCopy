import FontCopyCore
import Foundation
import Testing

@Test func priorIdentityResolvesFromBackupAfterNormalization() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let fontURL = tempDirectory.appendingPathComponent("规范化后的名称.ttf")
    try FileManager.default.copyItem(at: try systemTTFFontURL(), to: fontURL)

    let originalMetadata = try #require(FontMetadataReader.metadata(for: fontURL).first)

    let result = FontNameNormalizerService().normalizeFile(at: fontURL)
    #expect(result.status == .success)
    #expect(result.priorPostScriptName == originalMetadata.postScriptName)
    #expect(result.priorFamilyName == originalMetadata.familyName)

    let prior = try #require(PriorFontIdentityResolver.resolve(for: fontURL))
    #expect(prior.postScriptName == originalMetadata.postScriptName)
    #expect(prior.familyName == originalMetadata.familyName)
    #expect(prior.backupURL.lastPathComponent == "规范化后的名称.ttf.bak")
}

@Test func priorIdentityReturnsNilWhenNoBackupExists() async throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let fontURL = tempDirectory.appendingPathComponent("从未规范化.ttf")
    try FileManager.default.copyItem(at: try systemTTFFontURL(), to: fontURL)

    #expect(PriorFontIdentityResolver.resolve(for: fontURL) == nil)
}

@Test func snapshotExposesURLsByPostScriptNameAndFiltersRemovableRoots() async throws {
    let installedRoot = try makeTemporaryDirectory()
    let systemRoot = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: installedRoot)
        try? FileManager.default.removeItem(at: systemRoot)
    }

    let installableFont = installedRoot.appendingPathComponent("可移除字体.ttf")
    let systemFont = systemRoot.appendingPathComponent("系统字体.ttf")
    try FileManager.default.copyItem(at: try systemTTFFontURL(), to: installableFont)
    try FileManager.default.copyItem(at: try systemTTFFontURL(), to: systemFont)

    var registerError: Unmanaged<CFError>?
    _ = CTFontManagerRegisterFontsForURL(installableFont as CFURL, .user, &registerError)
    _ = CTFontManagerRegisterFontsForURL(systemFont as CFURL, .user, &registerError)
    defer {
        var unregisterError: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(installableFont as CFURL, .user, &unregisterError)
        CTFontManagerUnregisterFontsForURL(systemFont as CFURL, .user, &unregisterError)
    }

    let service = InstalledFontService(
        installedFontRoots: [installedRoot, systemRoot],
        userRemovableRoots: [installedRoot]
    )
    let snapshot = service.snapshot()

    let metadata = try #require(FontMetadataReader.metadata(for: installableFont).first)
    let urls = snapshot.urlsByPostScriptName[metadata.postScriptName] ?? []
    #expect(!urls.isEmpty)

    let removable = snapshot.removableInstalledURLs(forPostScriptName: metadata.postScriptName)
    #expect(removable.contains(where: { $0.path.hasPrefix(installedRoot.path) }))
    #expect(!removable.contains(where: { $0.path.hasPrefix(systemRoot.path) }))
}

import CoreText

private func systemTTFFontURL() throws -> URL {
    let candidates = [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Geneva.ttf",
        "/System/Library/Fonts/SFNS.ttf"
    ]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        throw PriorFontIdentityTestError.missingSystemFont
    }
    return URL(fileURLWithPath: path)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FontCopyPriorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum PriorFontIdentityTestError: Error {
    case missingSystemFont
}
