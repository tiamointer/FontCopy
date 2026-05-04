import Foundation

public struct AppUpdate: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case dmg(URL)
        case app(URL)
    }

    public let version: String
    public let source: Source
    public let notes: String?

    public init(version: String, source: Source, notes: String? = nil) {
        self.version = version
        self.source = source
        self.notes = notes
    }
}

public enum UpdateError: Error, LocalizedError, Sendable {
    case folderUnreadable
    case mountFailed(String)
    case noAppInDmg
    case copyFailed(String)
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .folderUnreadable: return "无法访问指定文件夹"
        case .mountFailed(let m): return "挂载 DMG 失败：\(m)"
        case .noAppInDmg: return "DMG 内未找到 FontCopy.app"
        case .copyFailed(let m): return "复制失败：\(m)"
        case .scriptFailed(let m): return "升级脚本启动失败：\(m)"
        }
    }
}

public struct UpdateService: Sendable {
    public init() {}

    public func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public func scanForUpdate(in folder: URL, currentVersion: String? = nil) throws -> AppUpdate? {
        let current = currentVersion ?? self.currentVersion()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateError.folderUnreadable
        }

        var candidates: [AppUpdate] = []
        for url in entries {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()

            if ext == "dmg", name.hasPrefix("FontCopy"), let version = Self.extractVersion(fromFilename: name) {
                let notes = Self.readSidecarNotes(forDmg: url)
                candidates.append(AppUpdate(version: version, source: .dmg(url), notes: notes))
            } else if ext == "app", name.hasPrefix("FontCopy"), let version = Self.readBundleVersion(at: url) {
                let notes = Self.readBundleNotes(at: url)
                candidates.append(AppUpdate(version: version, source: .app(url), notes: notes))
            }
        }

        return candidates
            .filter { Self.compare($0.version, current) > 0 }
            .max(by: { Self.compare($0.version, $1.version) < 0 })
    }

    static func extractVersion(fromFilename name: String) -> String? {
        guard let range = name.range(of: #"(\d+\.\d+(?:\.\d+)?)"#, options: .regularExpression) else {
            return nil
        }
        return String(name[range])
    }

    static func readSidecarNotes(forDmg dmgURL: URL) -> String? {
        let base = dmgURL.deletingPathExtension().lastPathComponent
        let sidecar = dmgURL.deletingLastPathComponent().appendingPathComponent("\(base).notes.txt")
        guard let data = try? Data(contentsOf: sidecar),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    static func readBundleNotes(at appURL: URL) -> String? {
        let url = appURL.appendingPathComponent("Contents/Resources/ReleaseNotes.txt")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    static func readBundleVersion(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    public static func compare(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(aParts.count, bParts.count)
        for i in 0..<n {
            let x = i < aParts.count ? aParts[i] : 0
            let y = i < bParts.count ? bParts[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
