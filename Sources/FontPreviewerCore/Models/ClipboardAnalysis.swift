import Foundation

public enum ClipboardFontSource: String, Codable, Sendable {
    case rtf = "RTF"
    case html = "HTML"
}

public struct ClipboardFontMatch: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let source: ClipboardFontSource

    public init(name: String, source: ClipboardFontSource) {
        self.name = name
        self.source = source
    }
}

public struct ClipboardAnalysis: Sendable {
    public let rtf: String?
    public let html: String?
    public let plainText: String?
    public let fonts: [ClipboardFontMatch]

    public init(rtf: String?, html: String?, plainText: String?, fonts: [ClipboardFontMatch]) {
        self.rtf = rtf
        self.html = html
        self.plainText = plainText
        self.fonts = fonts
    }
}
