import Foundation

public struct PriorFontIdentity: Sendable, Equatable {
    public let postScriptName: String
    public let familyName: String
    public let backupURL: URL

    public init(postScriptName: String, familyName: String, backupURL: URL) {
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.backupURL = backupURL
    }
}

public enum PriorFontIdentityResolver {
    public static func resolve(for fontURL: URL) -> PriorFontIdentity? {
        let backupURL = URL(fileURLWithPath: fontURL.path + ".bak")
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return nil }
        guard let metadata = FontMetadataReader.metadata(for: backupURL).first else { return nil }
        return PriorFontIdentity(
            postScriptName: metadata.postScriptName,
            familyName: metadata.familyName,
            backupURL: backupURL
        )
    }
}
