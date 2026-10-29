import CoreText
import Foundation

/// 字体能显示简体还是繁体。两者都有 = 简繁通用；都没有 = 拉丁/像素等无法判断的字体。
public struct FontScriptSupport: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let simplified = FontScriptSupport(rawValue: 1 << 0)
    public static let traditional = FontScriptSupport(rawValue: 1 << 1)

    /// 简化字 / 繁体字专属字表里覆盖过半，才算支持。
    static let coverageThreshold = 0.5

    /// 按字体字符表判断；拿不到字符表返回 nil。
    public static func measure(_ descriptor: CTFontDescriptor) -> FontScriptSupport? {
        guard let charset = CTFontDescriptorCopyAttribute(descriptor, kCTFontCharacterSetAttribute) as? NSCharacterSet else {
            return nil
        }
        func covers(_ scalars: [UInt32]) -> Bool {
            let hits = scalars.reduce(0) { $0 + (charset.longCharacterIsMember($1) ? 1 : 0) }
            return Double(hits) >= Double(scalars.count) * coverageThreshold
        }
        var support: FontScriptSupport = []
        if covers(FontScriptCharacters.simplifiedOnly) { support.insert(.simplified) }
        if covers(FontScriptCharacters.traditionalOnly) { support.insert(.traditional) }
        return support
    }

    /// 字库约定：同一款字体的繁体版文件名带“繁体”，简体版带“简体”。
    /// 简繁通用的字体按名字归到一边，避免简体、繁体两个版本在两种筛选里都出现。
    public static func resolve(measured: FontScriptSupport, names: [String]) -> FontScriptSupport {
        guard measured == [.simplified, .traditional] else { return measured }
        let joined = names.joined(separator: " ")
        let saysTraditional = joined.contains("繁")
        let saysSimplified = joined.contains("简") || joined.contains("簡")
        if saysTraditional && !saysSimplified { return .traditional }
        if saysSimplified && !saysTraditional { return .simplified }
        return measured
    }

    /// 只隐藏明确不支持该文字的字体；判断不了的（空集）照常显示。
    public func isVisible(in filter: FontScriptFilter) -> Bool {
        switch filter {
        case .all: return true
        case .simplified: return self != .traditional
        case .traditional: return self != .simplified
        }
    }
}

public enum FontScriptFilter: String, CaseIterable, Sendable {
    case all
    case simplified
    case traditional

    public var displayName: String {
        switch self {
        case .all: return "全部"
        case .simplified: return "简体"
        case .traditional: return "繁体"
        }
    }
}
