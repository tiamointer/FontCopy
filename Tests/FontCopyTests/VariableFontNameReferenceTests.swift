import FontCopyCore
import Foundation
import Testing

// Regression: normalizing 源意明体 (variable, fvar/STAT/avar) once left fvar instance
// names 264-269 dangling, and After Effects refused to launch with
// "Unable to acquire ascii style name".

@Test func normalizingVariableFontKeepsEveryFvarAndSTATNameReference() async throws {
    let source = try systemVariableFont()
    try #require(try FontNameReferenceValidator.danglingReferences(at: source).isEmpty)

    let tempDirectory = try makeVariableFontTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fontURL = tempDirectory.appendingPathComponent("可变测试体.ttf")
    try FileManager.default.copyItem(at: source, to: fontURL)

    let result = FontNameNormalizerService().normalizeFile(at: fontURL)

    #expect(result.status == .success, "\(result.message)")
    #expect(try FontNameReferenceValidator.danglingReferences(at: fontURL).isEmpty)
    let metadata = FontMetadataReader.metadata(for: fontURL)
    #expect(metadata.contains { $0.familyName == "可变测试体" })
}

@Test func validatorReportsNameIDsMissingFromNameTable() async throws {
    var data = try Data(contentsOf: systemVariableFont())
    try removeNameRecords(withNameIDAtLeast: 256, from: &data)

    let dangling = try FontNameReferenceValidator.danglingReferences(in: data)

    #expect(!dangling.isEmpty)
    #expect(dangling.allSatisfy { $0.nameID >= 256 })
    #expect(Set(dangling.map(\.table)) == ["fvar", "STAT"])
}

@Test func normalizerRefusesFontWithDanglingNameReferences() async throws {
    var data = try Data(contentsOf: systemVariableFont())
    try removeNameRecords(withNameIDAtLeast: 256, from: &data)

    let tempDirectory = try makeVariableFontTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fontURL = tempDirectory.appendingPathComponent("坏可变体.ttf")
    try data.write(to: fontURL)

    let result = FontNameNormalizerService().normalizeFile(at: fontURL)

    #expect(result.status == .failed)
    #expect(result.message.contains("nameID"))
    #expect(try Data(contentsOf: fontURL) == data)
    #expect(!FileManager.default.fileExists(atPath: fontURL.path + ".bak"))
}

private func systemVariableFont() throws -> URL {
    let candidates = [
        "/System/Library/Fonts/NewYork.ttf",
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/SFNS.ttf"
    ]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        throw VariableFontTestError.missingSystemFont
    }
    return URL(fileURLWithPath: path)
}

/// Rewrites name records with nameID >= threshold to nameID 0xFFFE, emulating the
/// broken 源意明体 output without changing any table length.
private func removeNameRecords(withNameIDAtLeast threshold: UInt16, from data: inout Data) throws {
    func u16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
    func u32(_ offset: Int) -> Int { u16(offset) << 16 | u16(offset + 2) }
    let numTables = u16(4)
    guard let entry = (0..<numTables).map({ 12 + $0 * 16 }).first(where: {
        String(bytes: data[$0..<$0 + 4], encoding: .ascii) == "name"
    }) else {
        throw VariableFontTestError.missingNameTable
    }
    let nameOffset = u32(entry + 8)
    for index in 0..<u16(nameOffset + 2) {
        let nameIDOffset = nameOffset + 6 + index * 12 + 6
        if u16(nameIDOffset) >= Int(threshold) {
            data[nameIDOffset] = 0xFF
            data[nameIDOffset + 1] = 0xFE
        }
    }
}

private func makeVariableFontTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FontCopyVariableTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum VariableFontTestError: Error {
    case missingSystemFont
    case missingNameTable
}
