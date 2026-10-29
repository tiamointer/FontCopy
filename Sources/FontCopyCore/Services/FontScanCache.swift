import CryptoKit
import Foundation

public struct CachedFontMetadata: Codable, Sendable {
    public let postScriptName: String
    public let familyName: String
    public let styleName: String?
    public let displayName: String
    public let version: String?
    /// 旧版缓存没有这一项，读到 nil 会当作缓存未命中重新读取。
    public let scriptSupport: FontScriptSupport?
}

public struct CachedFontEntry: Codable, Sendable {
    public let relativePath: String
    public let fileSize: Int64
    public let modifiedAt: Double
    public let fileHash: String
    public let isUnsupported: Bool
    public let metadata: [CachedFontMetadata]
}

/// 扫描元数据缓存。按导入根目录持久化到 Application Support，
/// 缓存的是字体的元数据（很小），不是字体文件本身。
public struct FontScanCache: Sendable {
    public init() {}

    private var cacheRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FontCopy/scan-cache", isDirectory: true)
    }

    private func cacheFileURL(forRoot root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheRootDirectory.appendingPathComponent("\(key).json")
    }

    public func load(forRoot root: URL) -> [String: CachedFontEntry] {
        guard let data = try? Data(contentsOf: cacheFileURL(forRoot: root)),
              let entries = try? JSONDecoder().decode([CachedFontEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func save(forRoot root: URL, entries: [String: CachedFontEntry]) {
        let dir = cacheRootDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        try? data.write(to: cacheFileURL(forRoot: root))
    }
}
