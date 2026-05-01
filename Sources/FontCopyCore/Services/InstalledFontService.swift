import CoreText
import Foundation

public struct InstalledFontSnapshot: Sendable {
    public let postScriptNames: Set<String>
    public let fileHashesByPostScriptName: [String: Set<String>]

    public init(postScriptNames: Set<String>, fileHashesByPostScriptName: [String: Set<String>]) {
        self.postScriptNames = postScriptNames
        self.fileHashesByPostScriptName = fileHashesByPostScriptName
    }
}

public struct InstalledFontService: Sendable {
    private let installedFontRoots: [URL]

    public init() {
        self.init(installedFontRoots: Self.defaultInstalledFontRoots())
    }

    public init(installedFontRoots: [URL]) {
        self.installedFontRoots = installedFontRoots.map(Self.normalizedDirectoryURL)
    }

    public func snapshot() -> InstalledFontSnapshot {
        var postScriptNames: Set<String> = []
        var hashesByPostScriptName: [String: Set<String>] = [:]

        let availableURLs = (CTFontManagerCopyAvailableFontURLs() as NSArray as? [URL]) ?? []
        for url in availableURLs where isInstalledFontURL(url) {
            guard let hash = try? FileHash.sha256Hex(for: url) else { continue }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as NSArray? else { continue }

            for case let descriptor as CTFontDescriptor in descriptors {
                guard let postScriptName = FontMetadataReader.stringAttribute(descriptor, key: kCTFontNameAttribute) else { continue }
                postScriptNames.insert(postScriptName)
                hashesByPostScriptName[postScriptName, default: []].insert(hash)
            }
        }

        return InstalledFontSnapshot(
            postScriptNames: postScriptNames,
            fileHashesByPostScriptName: hashesByPostScriptName
        )
    }

    private func isInstalledFontURL(_ url: URL) -> Bool {
        let path = Self.normalizedFileURL(url).path
        return installedFontRoots.contains { root in
            let rootPath = root.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    private static func defaultInstalledFontRoots() -> [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Fonts", isDirectory: true),
            URL(fileURLWithPath: "/Network/Library/Fonts", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Fonts", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true)
        ]
    }

    private static func normalizedDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
