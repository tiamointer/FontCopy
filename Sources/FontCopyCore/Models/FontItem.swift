import Foundation

public struct FontItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let fileID: UUID
    public let sourceURL: URL
    public let relativePath: String
    public let displayName: String
    public let postScriptName: String
    public let familyName: String
    public let styleName: String?
    public let version: String?
    public let fileHash: String
    public let category: String
    public var installStatus: FontInstallStatus
    public var isFavorite: Bool
    public var isCompared: Bool
    public var installError: String?

    public init(
        id: UUID = UUID(),
        fileID: UUID,
        sourceURL: URL,
        relativePath: String,
        displayName: String,
        postScriptName: String,
        familyName: String,
        styleName: String?,
        version: String?,
        fileHash: String,
        category: String,
        installStatus: FontInstallStatus,
        isFavorite: Bool,
        isCompared: Bool,
        installError: String? = nil
    ) {
        self.id = id
        self.fileID = fileID
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.styleName = styleName
        self.version = version
        self.fileHash = fileHash
        self.category = category
        self.installStatus = installStatus
        self.isFavorite = isFavorite
        self.isCompared = isCompared
        self.installError = installError
    }

    public var fileExtension: String {
        sourceURL.pathExtension.lowercased()
    }

    public var isSupportedFontFile: Bool {
        Self.supportedExtensions.contains(fileExtension)
    }

    public var canNormalizeInternalName: Bool {
        Self.nameNormalizableExtensions.contains(fileExtension) && hasMismatchedInternalName
    }

    public var hasMismatchedInternalName: Bool {
        let expectedName = sourceURL.deletingPathExtension().lastPathComponent.normalizedFontIdentity
        guard !expectedName.isEmpty else { return false }
        let visibleNames = [
            displayName.normalizedFontIdentity,
            familyName.normalizedFontIdentity
        ]
        return !visibleNames.contains(expectedName)
    }

    public static let supportedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
    public static let fontLikeExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]
    public static let nameNormalizableExtensions: Set<String> = ["ttf", "otf"]
}

private extension String {
    var normalizedFontIdentity: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
    }
}
