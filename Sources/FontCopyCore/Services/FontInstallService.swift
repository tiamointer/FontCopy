import AppKit
import Foundation

public struct FontInstallResult: Sendable {
    public let installedFileIDs: Set<UUID>
    public let skippedFileIDs: Set<UUID>
    public let failed: [UUID: String]

    public init(installedFileIDs: Set<UUID>, skippedFileIDs: Set<UUID>, failed: [UUID: String]) {
        self.installedFileIDs = installedFileIDs
        self.skippedFileIDs = skippedFileIDs
        self.failed = failed
    }
}

public struct FontInstallService: Sendable {
    public init() {}

    public func installFonts(_ fonts: [FontItem]) -> FontInstallResult {
        let installableFonts = uniqueInstallableFiles(from: fonts)
        let skipped = Set(fonts.filter { !$0.installStatus.isInstallable || !$0.isSupportedFontFile }.map(\.fileID))
        guard !installableFonts.isEmpty else {
            return FontInstallResult(installedFileIDs: [], skippedFileIDs: skipped, failed: [:])
        }

        do {
            let stagedFiles = try stageFontsForPrivilegedInstall(installableFonts)
            defer {
                try? FileManager.default.removeItem(at: stagedFiles.stagingDirectory)
            }

            let copyCommands = stagedFiles.files.map { stagedFile in
                "/bin/cp -p \(PathUtilities.shellQuoted(stagedFile.stagedURL.path)) \(PathUtilities.shellQuoted(stagedFile.destinationURL.path))"
            }
            let command = """
            /bin/mkdir -p /Library/Fonts
            \(copyCommands.joined(separator: "\n"))
            """
            try runAsAdministrator(command)
            return FontInstallResult(
                installedFileIDs: Set(installableFonts.map(\.fileID)),
                skippedFileIDs: skipped,
                failed: [:]
            )
        } catch {
            let failed = Dictionary(uniqueKeysWithValues: installableFonts.map { ($0.fileID, error.localizedDescription) })
            return FontInstallResult(installedFileIDs: [], skippedFileIDs: skipped, failed: failed)
        }
    }

    private func stageFontsForPrivilegedInstall(_ fonts: [FontItem]) throws -> StagedInstallSet {
        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("FontCopyInstall-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var stagedFiles: [StagedInstallFile] = []
        do {
            for font in fonts {
                let destination = try destinationURL(for: font)
                let stagedName = "\(font.fileID.uuidString)-\(font.sourceURL.lastPathComponent)"
                let stagedURL = stagingDirectory.appendingPathComponent(stagedName)
                try fileManager.copyItem(at: font.sourceURL, to: stagedURL)
                stagedFiles.append(StagedInstallFile(
                    fileID: font.fileID,
                    stagedURL: stagedURL,
                    destinationURL: destination
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

    private func destinationURL(for font: FontItem) throws -> URL {
        let fontsDirectory = URL(fileURLWithPath: "/Library/Fonts", isDirectory: true)
        let ext = font.sourceURL.pathExtension
        let baseName = font.sourceURL.deletingPathExtension().lastPathComponent
        var candidate = fontsDirectory.appendingPathComponent(font.sourceURL.lastPathComponent)

        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let shortHash = FileHash.shortHash(font.fileHash.isEmpty ? UUID().uuidString : font.fileHash)
        candidate = fontsDirectory.appendingPathComponent("\(baseName)-\(shortHash).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
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
