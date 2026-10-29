import AppKit
import Foundation

public struct FontInstallResult: Sendable {
    public let installedFileIDs: Set<UUID>
    public let skippedFileIDs: Set<UUID>
    public let failed: [UUID: String]
    public let removedURLs: [URL]

    public init(installedFileIDs: Set<UUID>, skippedFileIDs: Set<UUID>, failed: [UUID: String], removedURLs: [URL] = []) {
        self.installedFileIDs = installedFileIDs
        self.skippedFileIDs = skippedFileIDs
        self.failed = failed
        self.removedURLs = removedURLs
    }
}

public struct FontInstallService: Sendable {
    public init() {}

    public func installFonts(
        _ fonts: [FontItem],
        removingURLs: [URL] = [],
        progress: ((FontInstallProgress) -> Void)? = nil
    ) -> FontInstallResult {
        var rejected: [UUID: String] = [:]
        let installableFonts = uniqueInstallableFiles(from: fonts).filter { font in
            if let reason = Self.nameReferenceProblem(for: font.sourceURL) {
                rejected[font.fileID] = reason
                return false
            }
            return true
        }
        let skipped = Set(fonts.filter { !$0.installStatus.isInstallable || !$0.isSupportedFontFile }.map(\.fileID))
        let uniqueRemovalURLs = Array(Set(removingURLs.map { $0.standardizedFileURL }))
        guard !installableFonts.isEmpty else {
            return FontInstallResult(installedFileIDs: [], skippedFileIDs: skipped, failed: rejected)
        }

        do {
            let stagedFiles = try stageFontsForPrivilegedInstall(
                installableFonts,
                removalURLs: uniqueRemovalURLs,
                progress: progress
            )
            defer {
                try? FileManager.default.removeItem(at: stagedFiles.stagingDirectory)
            }

            progress?(FontInstallProgress(
                phase: .applying,
                processed: stagedFiles.files.count,
                total: stagedFiles.files.count,
                currentName: nil
            ))

            let removalCommands = uniqueRemovalURLs.map { url in
                "/bin/rm -f \(PathUtilities.shellQuoted(url.path))"
            }
            let copyCommands = stagedFiles.files.map { stagedFile in
                "/bin/cp -p \(PathUtilities.shellQuoted(stagedFile.stagedURL.path)) \(PathUtilities.shellQuoted(stagedFile.destinationURL.path))"
            }
            let command = ([
                "/bin/mkdir -p /Library/Fonts"
            ] + removalCommands + copyCommands).joined(separator: "\n")
            try runAsAdministrator(command)

            progress?(FontInstallProgress(
                phase: .verifying,
                processed: stagedFiles.files.count,
                total: stagedFiles.files.count,
                currentName: nil
            ))

            return FontInstallResult(
                installedFileIDs: Set(installableFonts.map(\.fileID)),
                skippedFileIDs: skipped,
                failed: rejected,
                removedURLs: uniqueRemovalURLs
            )
        } catch {
            let failed = Dictionary(uniqueKeysWithValues: installableFonts.map { ($0.fileID, error.localizedDescription) })
                .merging(rejected) { current, _ in current }
            return FontInstallResult(installedFileIDs: [], skippedFileIDs: skipped, failed: failed)
        }
    }

    /// Fonts whose fvar/STAT reference missing name records break apps like
    /// After Effects at launch once they sit in /Library/Fonts, so never install them.
    static func nameReferenceProblem(for url: URL) -> String? {
        guard let dangling = try? FontNameReferenceValidator.danglingReferences(at: url), !dangling.isEmpty else {
            return nil
        }
        return FontNameReferenceValidator.describe(dangling)
    }

    private func stageFontsForPrivilegedInstall(
        _ fonts: [FontItem],
        removalURLs: [URL],
        progress: ((FontInstallProgress) -> Void)? = nil
    ) throws -> StagedInstallSet {
        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("FontCopyInstall-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let removalPaths = Set(removalURLs.map { $0.standardizedFileURL.path })
        var stagedFiles: [StagedInstallFile] = []
        let total = fonts.count
        progress?(FontInstallProgress(
            phase: .staging,
            processed: 0,
            total: total,
            currentName: fonts.first?.sourceURL.lastPathComponent
        ))
        do {
            for (index, font) in fonts.enumerated() {
                progress?(FontInstallProgress(
                    phase: .staging,
                    processed: index,
                    total: total,
                    currentName: font.sourceURL.lastPathComponent
                ))
                let destination = try destinationURL(for: font, removalSet: removalPaths)
                let stagedName = "\(font.fileID.uuidString)-\(font.sourceURL.lastPathComponent)"
                let stagedURL = stagingDirectory.appendingPathComponent(stagedName)
                try fileManager.copyItem(at: font.sourceURL, to: stagedURL)
                stagedFiles.append(StagedInstallFile(
                    fileID: font.fileID,
                    stagedURL: stagedURL,
                    destinationURL: destination
                ))
                progress?(FontInstallProgress(
                    phase: .staging,
                    processed: index + 1,
                    total: total,
                    currentName: index + 1 < total ? fonts[index + 1].sourceURL.lastPathComponent : nil
                ))
            }
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }

        return StagedInstallSet(stagingDirectory: stagingDirectory, files: stagedFiles)
    }

    private func uniqueInstallableFiles(from fonts: [FontItem]) -> [FontItem] {
        var seen = Set<UUID>()
        var unique: [FontItem] = []

        for font in fonts where font.installStatus.isInstallable && font.isSupportedFontFile {
            guard !seen.contains(font.fileID) else { continue }
            seen.insert(font.fileID)
            unique.append(font)
        }

        return unique
    }

    private func destinationURL(for font: FontItem, removalSet: Set<String>) throws -> URL {
        let fontsDirectory = URL(fileURLWithPath: "/Library/Fonts", isDirectory: true)
        let ext = font.sourceURL.pathExtension
        let baseName = font.sourceURL.deletingPathExtension().lastPathComponent
        var candidate = fontsDirectory.appendingPathComponent(font.sourceURL.lastPathComponent)

        if !FileManager.default.fileExists(atPath: candidate.path) || removalSet.contains(candidate.standardizedFileURL.path) {
            return candidate
        }

        let shortHash = FileHash.shortHash(font.fileHash.isEmpty ? UUID().uuidString : font.fileHash)
        candidate = fontsDirectory.appendingPathComponent("\(baseName)-\(shortHash).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path),
              !removalSet.contains(candidate.standardizedFileURL.path) {
            candidate = fontsDirectory.appendingPathComponent("\(baseName)-\(shortHash)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func runAsAdministrator(_ command: String) throws {
        let scriptSource = "do shell script \(PathUtilities.appleScriptStringLiteral(command)) with administrator privileges"
        guard let script = NSAppleScript(source: scriptSource) else {
            throw FontInstallError.appleScriptCreationFailed
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            if code == -128 {
                throw FontInstallError.authorizationCancelled
            }
            throw FontInstallError.appleScriptFailed(message ?? "系统字体安装失败")
        }
    }
}

private struct StagedInstallSet {
    let stagingDirectory: URL
    let files: [StagedInstallFile]
}

private struct StagedInstallFile {
    let fileID: UUID
    let stagedURL: URL
    let destinationURL: URL
}

public enum FontInstallError: LocalizedError, Sendable {
    case appleScriptCreationFailed
    case authorizationCancelled
    case appleScriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appleScriptCreationFailed:
            return "无法创建管理员授权脚本"
        case .authorizationCancelled:
            return "用户取消了管理员授权"
        case .appleScriptFailed(let message):
            return message
        }
    }
}
