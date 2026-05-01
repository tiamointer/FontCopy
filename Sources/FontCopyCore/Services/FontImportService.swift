import Foundation

public enum FontImportConflict: Sendable, Equatable {
    case destinationFilenameCollision(URL)
    case sameContentInLibrary(FontItem)
    case samePostScriptInLibrary(FontItem)
}

public struct FontImportEvaluation: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let category: String
    public let sha256: String
    public let postScriptNames: [String]
    public let conflicts: [FontImportConflict]

    public init(
        sourceURL: URL,
        destinationURL: URL,
        category: String,
        sha256: String,
        postScriptNames: [String],
        conflicts: [FontImportConflict]
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.category = category
        self.sha256 = sha256
        self.postScriptNames = postScriptNames
        self.conflicts = conflicts
    }

    public var hasConflict: Bool { !conflicts.isEmpty }
}

public enum FontImportRejection: LocalizedError, Sendable {
    case unsupportedExtension(URL)
    case sourceInsideImportedRoot(URL)
    case unreadable(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let url):
            return "“\(url.lastPathComponent)”不是支持的字体格式"
        case .sourceInsideImportedRoot(let url):
            return "“\(url.lastPathComponent)”已在字体库内，请用 Finder 移动后重新扫描"
        case .unreadable(let url, let reason):
            return "无法读取“\(url.lastPathComponent)”：\(reason)"
        }
    }
}

public struct FontImportService: Sendable {
    public init() {}

    public func evaluate(
        sourceURL: URL,
        intoCategory category: String,
        importedRoot: URL,
        libraryFonts: [FontItem]
    ) throws -> FontImportEvaluation {
        let ext = sourceURL.pathExtension.lowercased()
        guard FontItem.fontLikeExtensions.contains(ext) else {
            throw FontImportRejection.unsupportedExtension(sourceURL)
        }

        if Self.isURL(sourceURL, inside: importedRoot) {
            throw FontImportRejection.sourceInsideImportedRoot(sourceURL)
        }

        let hash: String
        do {
            hash = try FileHash.sha256Hex(for: sourceURL)
        } catch {
            throw FontImportRejection.unreadable(sourceURL, error.localizedDescription)
        }

        let metadata = FontMetadataReader.metadata(for: sourceURL)
        let postScriptNames = metadata.map(\.postScriptName)
        let destinationURL = Self.destinationURL(
            for: sourceURL,
            intoCategory: category,
            importedRoot: importedRoot
        )

        var conflicts: [FontImportConflict] = []

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            conflicts.append(.destinationFilenameCollision(destinationURL))
        }

        var seenSameContentFileIDs = Set<UUID>()
        var seenSamePostScriptFileIDs = Set<UUID>()
        let postScriptSet = Set(postScriptNames)

        for font in libraryFonts {
            if !font.fileHash.isEmpty, font.fileHash == hash, seenSameContentFileIDs.insert(font.fileID).inserted {
                conflicts.append(.sameContentInLibrary(font))
                continue
            }
            if postScriptSet.contains(font.postScriptName),
               (font.fileHash != hash || font.fileHash.isEmpty),
               seenSamePostScriptFileIDs.insert(font.fileID).inserted {
                conflicts.append(.samePostScriptInLibrary(font))
            }
        }

        return FontImportEvaluation(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            category: category,
            sha256: hash,
            postScriptNames: postScriptNames,
            conflicts: conflicts
        )
    }

    public static func destinationURL(
        for sourceURL: URL,
        intoCategory category: String,
        importedRoot: URL
    ) -> URL {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRoot = importedRoot.standardizedFileURL
        if trimmed.isEmpty || trimmed == "未分类" {
            return normalizedRoot.appendingPathComponent(sourceURL.lastPathComponent)
        }
        let components = trimmed.split(separator: "/").map(String.init)
        var url = normalizedRoot
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        return url.appendingPathComponent(sourceURL.lastPathComponent)
    }

    private static func isURL(_ url: URL, inside root: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        return normalizedURL == normalizedRoot || normalizedURL.hasPrefix(normalizedRoot + "/")
    }
}

public struct FontImportPlan: Sendable {
    public enum ConflictMode: Sendable {
        case skip
        case overwrite
    }

    public let evaluations: [FontImportEvaluation]
    public let conflictMode: ConflictMode

    public init(evaluations: [FontImportEvaluation], conflictMode: ConflictMode) {
        self.evaluations = evaluations
        self.conflictMode = conflictMode
    }

    public var executableEvaluations: [FontImportEvaluation] {
        switch conflictMode {
        case .overwrite: return evaluations
        case .skip: return evaluations.filter { !$0.hasConflict }
        }
    }

    public var filesToRemove: [URL] {
        guard conflictMode == .overwrite else { return [] }
        var urls: Set<URL> = []
        for evaluation in evaluations where evaluation.hasConflict {
            for conflict in evaluation.conflicts {
                switch conflict {
                case .destinationFilenameCollision(let url):
                    urls.insert(url.standardizedFileURL)
                case .sameContentInLibrary(let font), .samePostScriptInLibrary(let font):
                    urls.insert(font.sourceURL.standardizedFileURL)
                }
            }
        }
        return Array(urls)
    }

    public var copyOperations: [(source: URL, destination: URL)] {
        executableEvaluations.map { ($0.sourceURL, $0.destinationURL) }
    }
}
