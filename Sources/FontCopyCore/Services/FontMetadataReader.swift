import CoreText
import Foundation

public struct FontMetadata: Sendable {
    public let postScriptName: String
    public let familyName: String
    public let styleName: String?
    public let displayName: String
    public let version: String?
    /// 实测的简繁支持（未按名字归类）；nil = 没测到。
    public let scriptSupport: FontScriptSupport?

    public init(postScriptName: String, familyName: String, styleName: String?, displayName: String, version: String?,
                scriptSupport: FontScriptSupport? = nil) {
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.styleName = styleName
        self.displayName = displayName
        self.version = version
        self.scriptSupport = scriptSupport
    }
}

public enum FontMetadataReader {
    public static func metadata(for url: URL) -> [FontMetadata] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as NSArray? else {
            return []
        }

        return descriptors.compactMap { value in
            let descriptor = value as! CTFontDescriptor
            let fallbackName = url.deletingPathExtension().lastPathComponent
            let postScriptName = stringAttribute(descriptor, key: kCTFontNameAttribute) ?? fallbackName
            let familyName = stringAttribute(descriptor, key: kCTFontFamilyNameAttribute) ?? postScriptName
            let styleName = stringAttribute(descriptor, key: kCTFontStyleNameAttribute)
            let displayName = stringAttribute(descriptor, key: kCTFontDisplayNameAttribute) ?? postScriptName
            let version: String? = nil

            return FontMetadata(
                postScriptName: postScriptName,
                familyName: familyName,
                styleName: styleName,
                displayName: displayName,
                version: version,
                scriptSupport: FontScriptSupport.measure(descriptor)
            )
        }
    }

    public static func stringAttribute(_ descriptor: CTFontDescriptor, key: CFString) -> String? {
        CTFontDescriptorCopyAttribute(descriptor, key) as? String
    }
}
