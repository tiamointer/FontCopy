import Foundation

public struct FontScanResult: Sendable {
    public let fonts: [FontItem]
    public let skipped: [SkippedFontFile]

    public init(fonts: [FontItem], skipped: [SkippedFontFile]) {
        self.fonts = fonts
        self.skipped = skipped
    }
}

public struct SkippedFontFile: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}
