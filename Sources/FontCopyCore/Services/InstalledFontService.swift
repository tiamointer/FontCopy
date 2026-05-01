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
    public init() {}

    public func snapshot() -> InstalledFontSnapshot {
        let postScriptNames = Set((CTFontManagerCopyAvailablePostScriptNames() as NSArray as? [String]) ?? [])
        var hashesByPostScriptName: [String: Set<String>] = [:]

        let availableURLs = (CTFontManagerCopyAvailableFontURLs() as NSArray as? [URL]) ?? []
        for url in availableURLs {
            guard let hash = try? FileHash.sha256Hex(for: url) else { continue }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as NSArray? else { continue }

            for case let descriptor as CTFontDescriptor in descriptors {
                guard let postScriptName = FontMetadataReader.stringAttribute(descriptor, key: kCTFontNameAttribute) else { continue }
                hashesByPostScriptName[postScriptName, default: []].insert(hash)
            }
        }

        return InstalledFontSnapshot(
            postScriptNames: postScriptNames,
            fileHashesByPostScriptName: hashesByPostScriptName
        )
    }
}
