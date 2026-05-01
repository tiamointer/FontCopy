import FontCopyCore
import Foundation
import Testing

@Test func evaluatesNoConflictWhenLibraryEmpty() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let evaluation = try FontImportService().evaluate(
        sourceURL: workspace.sourceFontURL,
        intoCategory: "中文",
        importedRoot: workspace.importedRoot,
        libraryFonts: []
    )

    #expect(!evaluation.hasConflict)
    #expect(evaluation.destinationURL.path == workspace.importedRoot
        .appendingPathComponent("中文")
        .appendingPathComponent(workspace.sourceFontURL.lastPathComponent).path)
    #expect(!evaluation.sha256.isEmpty)
}

@Test func detectsDestinationFilenameCollision() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let categoryDir = workspace.importedRoot.appendingPathComponent("中文")
    try FileManager.default.createDirectory(at: categoryDir, withIntermediateDirectories: true)
    let collidingURL = categoryDir.appendingPathComponent(workspace.sourceFontURL.lastPathComponent)
    try Data("placeholder".utf8).write(to: collidingURL)

    let evaluation = try FontImportService().evaluate(
        sourceURL: workspace.sourceFontURL,
        intoCategory: "中文",
        importedRoot: workspace.importedRoot,
        libraryFonts: []
    )

    #expect(evaluation.hasConflict)
    #expect(evaluation.conflicts.contains { conflict in
        if case .destinationFilenameCollision(let url) = conflict {
            return url.standardizedFileURL == collidingURL.standardizedFileURL
        }
        return false
    })
}

@Test func detectsSameHashInLibraryAcrossCategories() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let existingHash = try FileHash.sha256Hex(for: workspace.sourceFontURL)
    let existingFont = makeFontItem(
        sourceURL: workspace.importedRoot.appendingPathComponent("英文/Helvetica-old.ttf"),
        relativePath: "英文/Helvetica-old.ttf",
        postScriptName: "OldPS",
        fileHash: existingHash
    )

    let evaluation = try FontImportService().evaluate(
        sourceURL: workspace.sourceFontURL,
        intoCategory: "中文",
        importedRoot: workspace.importedRoot,
        libraryFonts: [existingFont]
    )

    #expect(evaluation.hasConflict)
    #expect(evaluation.conflicts.contains { conflict in
        if case .sameContentInLibrary(let font) = conflict { return font.id == existingFont.id }
        return false
    })
}

@Test func detectsSamePostScriptDifferentHash() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let postScript = try #require(FontMetadataReader.metadata(for: workspace.sourceFontURL).first?.postScriptName)
    let existingFont = makeFontItem(
        sourceURL: workspace.importedRoot.appendingPathComponent("中文/conflicting.ttf"),
        relativePath: "中文/conflicting.ttf",
        postScriptName: postScript,
        fileHash: "ffffffff"
    )

    let evaluation = try FontImportService().evaluate(
        sourceURL: workspace.sourceFontURL,
        intoCategory: "中文",
        importedRoot: workspace.importedRoot,
        libraryFonts: [existingFont]
    )

    #expect(evaluation.conflicts.contains { conflict in
        if case .samePostScriptInLibrary(let font) = conflict { return font.id == existingFont.id }
        return false
    })
}

@Test func rejectsSourceInsideImportedRoot() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let insideURL = workspace.importedRoot.appendingPathComponent("中文/inside.ttf")
    try FileManager.default.createDirectory(at: insideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: workspace.sourceFontURL, to: insideURL)

    let service = FontImportService()
    do {
        _ = try service.evaluate(
            sourceURL: insideURL,
            intoCategory: "英文",
            importedRoot: workspace.importedRoot,
            libraryFonts: []
        )
        Issue.record("Expected sourceInsideImportedRoot rejection")
    } catch FontImportRejection.sourceInsideImportedRoot {
        // success
    }
}

@Test func evaluatesMultipleConflictTypesOnSameFile() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let categoryDir = workspace.importedRoot.appendingPathComponent("中文")
    try FileManager.default.createDirectory(at: categoryDir, withIntermediateDirectories: true)
    let collidingURL = categoryDir.appendingPathComponent(workspace.sourceFontURL.lastPathComponent)
    try Data("placeholder".utf8).write(to: collidingURL)

    let existingHash = try FileHash.sha256Hex(for: workspace.sourceFontURL)
    let existingFont = makeFontItem(
        sourceURL: workspace.importedRoot.appendingPathComponent("英文/Helvetica-old.ttf"),
        relativePath: "英文/Helvetica-old.ttf",
        postScriptName: "OldPS",
        fileHash: existingHash
    )

    let evaluation = try FontImportService().evaluate(
        sourceURL: workspace.sourceFontURL,
        intoCategory: "中文",
        importedRoot: workspace.importedRoot,
        libraryFonts: [existingFont]
    )

    let kinds = evaluation.conflicts.map { conflict -> String in
        switch conflict {
        case .destinationFilenameCollision: return "filename"
        case .sameContentInLibrary: return "content"
        case .samePostScriptInLibrary: return "postscript"
        }
    }
    #expect(kinds.contains("filename"))
    #expect(kinds.contains("content"))
}

@Test func planFiltersConflictingFilesWhenSkipping() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let cleanEvaluation = FontImportEvaluation(
        sourceURL: workspace.sourceFontURL,
        destinationURL: workspace.importedRoot.appendingPathComponent("中文/clean.ttf"),
        category: "中文",
        sha256: "aaaa",
        postScriptNames: ["A"],
        conflicts: []
    )
    let conflictingEvaluation = FontImportEvaluation(
        sourceURL: workspace.sourceFontURL,
        destinationURL: workspace.importedRoot.appendingPathComponent("中文/dup.ttf"),
        category: "中文",
        sha256: "bbbb",
        postScriptNames: ["B"],
        conflicts: [.destinationFilenameCollision(workspace.importedRoot.appendingPathComponent("中文/dup.ttf"))]
    )
    let plan = FontImportPlan(
        evaluations: [cleanEvaluation, conflictingEvaluation],
        conflictMode: .skip
    )

    #expect(plan.executableEvaluations.count == 1)
    #expect(plan.filesToRemove.isEmpty)
    #expect(plan.copyOperations.count == 1)
}

@Test func planRemovesAllMatchedURLsWhenOverwriting() async throws {
    let workspace = try makeImportWorkspace()
    defer { workspace.cleanup() }

    let collisionURL = workspace.importedRoot.appendingPathComponent("中文/dup.ttf")
    let existingFont = makeFontItem(
        sourceURL: workspace.importedRoot.appendingPathComponent("英文/old.ttf"),
        relativePath: "英文/old.ttf",
        postScriptName: "OldPS",
        fileHash: "abc123"
    )
    let evaluation = FontImportEvaluation(
        sourceURL: workspace.sourceFontURL,
        destinationURL: collisionURL,
        category: "中文",
        sha256: "abc123",
        postScriptNames: ["A"],
        conflicts: [
            .destinationFilenameCollision(collisionURL),
            .sameContentInLibrary(existingFont)
        ]
    )
    let plan = FontImportPlan(evaluations: [evaluation], conflictMode: .overwrite)

    #expect(Set(plan.filesToRemove.map(\.path)) == Set([
        collisionURL.standardizedFileURL.path,
        existingFont.sourceURL.standardizedFileURL.path
    ]))
    #expect(plan.copyOperations.count == 1)
}

private struct ImportTestWorkspace {
    let importedRoot: URL
    let sourceRoot: URL
    let sourceFontURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: importedRoot)
        try? FileManager.default.removeItem(at: sourceRoot)
    }
}

private func makeImportWorkspace() throws -> ImportTestWorkspace {
    let baseTemp = FileManager.default.temporaryDirectory
    let importedRoot = baseTemp.appendingPathComponent("FontCopyImportTests-imported-\(UUID().uuidString)", isDirectory: true)
    let sourceRoot = baseTemp.appendingPathComponent("FontCopyImportTests-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: importedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

    let systemFont = try systemTTFFontURL()
    let sourceFontURL = sourceRoot.appendingPathComponent("拖入字体.ttf")
    try FileManager.default.copyItem(at: systemFont, to: sourceFontURL)

    return ImportTestWorkspace(
        importedRoot: importedRoot,
        sourceRoot: sourceRoot,
        sourceFontURL: sourceFontURL
    )
}

private func makeFontItem(
    sourceURL: URL,
    relativePath: String,
    postScriptName: String,
    fileHash: String
) -> FontItem {
    FontItem(
        fileID: UUID(),
        sourceURL: sourceURL,
        relativePath: relativePath,
        displayName: postScriptName,
        postScriptName: postScriptName,
        familyName: postScriptName,
        styleName: nil,
        version: nil,
        fileHash: fileHash,
        category: relativePath.split(separator: "/").dropLast().joined(separator: "/"),
        installStatus: .missing,
        isFavorite: false,
        isCompared: false
    )
}

private func systemTTFFontURL() throws -> URL {
    let candidates = [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Geneva.ttf",
        "/System/Library/Fonts/SFNS.ttf"
    ]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        throw ImportTestError.missingSystemFont
    }
    return URL(fileURLWithPath: path)
}

private enum ImportTestError: Error {
    case missingSystemFont
}
