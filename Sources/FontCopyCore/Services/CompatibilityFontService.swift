import CryptoKit
import Foundation

public struct CompatibilityResult: Sendable {
    public let installedCount: Int
    public let failed: [String: String]

    public init(installedCount: Int, failed: [String: String]) {
        self.installedCount = installedCount
        self.failed = failed
    }
}

public struct CompatibilityProgress: Sendable {
    public let processed: Int
    public let total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }
}

public struct CompatibilityFontService: Sendable {
    public init() {}

    public var compatDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts/FontCopyCompat", isDirectory: true)
    }

    private var manifestURL: URL {
        compatDirectory.appendingPathComponent(".fontcopy-compat-manifest.json")
    }

    public func enable(
        scanRoot: URL,
        progress: ((CompatibilityProgress) -> Void)? = nil
    ) -> CompatibilityResult {
        let fileManager = FileManager.default
        let backups = backupFiles(under: scanRoot)
        guard !backups.isEmpty else {
            return CompatibilityResult(installedCount: 0, failed: [:])
        }

        do {
            try fileManager.createDirectory(at: compatDirectory, withIntermediateDirectories: true)
        } catch {
            return CompatibilityResult(
                installedCount: 0,
                failed: [compatDirectory.path: error.localizedDescription]
            )
        }

        var usedNames = Set<String>()
        var installedNames: [String] = []
        var failed: [String: String] = [:]
        let total = backups.count

        for (index, backup) in backups.enumerated() {
            progress?(CompatibilityProgress(processed: index, total: total))
            let restoredName = restoredFileName(for: backup)
            let targetName = uniqueName(restoredName, source: backup, used: &usedNames)
            let destination = compatDirectory.appendingPathComponent(targetName)
            if let problem = FontInstallService.nameReferenceProblem(for: backup) {
                failed[backup.path] = problem
                continue
            }
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: backup, to: destination)
                // 源字体可能带 uchg(用户不可变)锁，copyItem 会一并复制，
                // 导致 disable 时删不掉。复制后立即清除，保证可删除。
                clearImmutableFlag(at: destination)
                installedNames.append(targetName)
            } catch {
                failed[backup.path] = error.localizedDescription
            }
        }
        progress?(CompatibilityProgress(processed: total, total: total))

        writeManifest(names: installedNames)
        return CompatibilityResult(installedCount: installedNames.count, failed: failed)
    }

    @discardableResult
    public func disable() -> CompatibilityResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: compatDirectory.path) else {
            return CompatibilityResult(installedCount: 0, failed: [:])
        }
        // 兼容字体可能带 uchg 锁（从源文件复制而来）；先递归清锁再删，否则 EPERM。
        clearImmutableFlag(at: compatDirectory)
        if let enumerator = fileManager.enumerator(at: compatDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                clearImmutableFlag(at: url)
            }
        }
        do {
            try fileManager.removeItem(at: compatDirectory)
            return CompatibilityResult(installedCount: 0, failed: [:])
        } catch {
            let remaining = (try? fileManager.contentsOfDirectory(atPath: compatDirectory.path))?
                .filter { !$0.hasPrefix(".") }.count ?? 0
            return CompatibilityResult(
                installedCount: remaining,
                failed: [compatDirectory.path: error.localizedDescription]
            )
        }
    }

    private func clearImmutableFlag(at url: URL) {
        var values = URLResourceValues()
        values.isUserImmutable = false
        var target = url
        try? target.setResourceValues(values)
    }

    public func installedCount() -> Int {
        if let names = readManifest() {
            return names.count
        }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: compatDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }.count
    }

    // MARK: - Helpers

    private func backupFiles(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular, PathUtilities.isFontCopyBackupFile(url) else { continue }
            result.append(url)
        }
        return result
    }

    // 你好.ttf.bak -> 你好.ttf ; 你好.ttf.bak-2 -> 你好.ttf
    private func restoredFileName(for backup: URL) -> String {
        let name = backup.lastPathComponent
        var components = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let last = components.last,
           last.lowercased() == "bak" || last.lowercased().hasPrefix("bak-") {
            components.removeLast()
        }
        let restored = components.joined(separator: ".")
        return restored.isEmpty ? name : restored
    }

    private func uniqueName(
        _ name: String,
        source: URL,
        used: inout Set<String>
    ) -> String {
        if !used.contains(name) {
            used.insert(name)
            return name
        }
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let digest = SHA256.hash(data: Data(source.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let shortHash = FileHash.shortHash(hex)
        var candidate = ext.isEmpty ? "\(base)-\(shortHash)" : "\(base)-\(shortHash).\(ext)"
        var counter = 2
        while used.contains(candidate) {
            candidate = ext.isEmpty
                ? "\(base)-\(shortHash)-\(counter)"
                : "\(base)-\(shortHash)-\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private struct Manifest: Codable {
        let installedNames: [String]
        let createdAt: Date
    }

    private func writeManifest(names: [String]) {
        let manifest = Manifest(installedNames: names, createdAt: Date())
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL)
    }

    private func readManifest() -> [String]? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        return manifest.installedNames
    }
}
