import CoreText
import Foundation

/// One library font whose installed copy differs from the library file, and
/// what updating it to the library version would do.
public struct FontVersionUpdate: Sendable, Identifiable {
    public enum Direction: Sendable {
        case libraryNewer
        case sameVersion
        case installedNewer
        case unknown
    }

    public let font: FontItem
    public let libraryVersion: String?
    public let installedVersion: String?
    public let installedURLs: [URL]
    public let direction: Direction
    public let blockedReason: String?

    public var id: UUID { font.id }

    /// The library is the source of truth, except when the machine already has a
    /// newer build than the library (that one belongs in the library instead).
    public var isUpdatable: Bool {
        blockedReason == nil && direction != .installedNewer
    }

    public var versionSummary: String {
        "\(FontUpdatePlanner.shortVersion(installedVersion)) → \(FontUpdatePlanner.shortVersion(libraryVersion))"
    }
}

public enum FontUpdatePlanner {
    public static func plan(
        for fonts: [FontItem],
        snapshot: InstalledFontSnapshot,
        readVersion: (URL, String) -> String? = versionString,
        libraryProblem: (URL) -> String? = FontInstallService.nameReferenceProblem(for:),
        faceNames: (URL) -> Set<String> = postScriptNames
    ) -> [FontVersionUpdate] {
        var namesByInstalledURL: [URL: Set<String>] = [:]
        for (name, urls) in snapshot.urlsByPostScriptName {
            for url in urls { namesByInstalledURL[url, default: []].insert(name) }
        }
        let updatingNames = Set(fonts.map(\.postScriptName))

        return fonts.map { font in
            let installedURLs = (snapshot.urlsByPostScriptName[font.postScriptName] ?? [])
                .sorted { $0.path < $1.path }
            let removableURLs = snapshot.removableInstalledURLs(forPostScriptName: font.postScriptName)
            let libraryVersion = readVersion(font.sourceURL, font.postScriptName)
            let installedVersion = installedURLs.compactMap { readVersion($0, font.postScriptName) }.first

            // Faces of the library file (e.g. a variable font's named instances) are replaced together.
            let replacedNames = updatingNames.union(faceNames(font.sourceURL))
            var blockedReason: String?
            if libraryProblem(font.sourceURL) != nil {
                blockedReason = "库里这份的名称表有缺陷，装了会让 After Effects 等软件报错"
            } else if installedURLs.isEmpty {
                blockedReason = "系统里没有找到已安装的文件"
            } else if removableURLs.count < installedURLs.count {
                blockedReason = "装在系统保护目录里，不能替换"
            } else if let shared = removableURLs.first(where: { !(namesByInstalledURL[$0] ?? []).isSubset(of: replacedNames) }) {
                blockedReason = "已安装的「\(shared.lastPathComponent)」是合集，还包含其他字体"
            }

            return FontVersionUpdate(
                font: font,
                libraryVersion: libraryVersion,
                installedVersion: installedVersion,
                installedURLs: removableURLs,
                direction: direction(library: libraryVersion, installed: installedVersion),
                blockedReason: blockedReason
            )
        }
    }

    public static func direction(library: String?, installed: String?) -> FontVersionUpdate.Direction {
        guard let library, let installed,
              let order = compareVersions(library, installed) else { return .unknown }
        switch order {
        case .orderedDescending: return .libraryNewer
        case .orderedAscending: return .installedNewer
        case .orderedSame: return .sameVersion
        }
    }

    /// Compares the first version number in each string ("Version 1.522; ttfautohint" → 1.522).
    /// Two-part numbers are font revisions (1.5 == 1.500 < 1.522); longer ones compare part by part.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = versionParts(lhs), let b = versionParts(rhs) else { return nil }
        if a.count == 2, b.count == 2,
           let x = Decimal(string: a.joined(separator: ".")),
           let y = Decimal(string: b.joined(separator: ".")) {
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? Int(a[index]) ?? 0 : 0
            let y = index < b.count ? Int(b[index]) ?? 0 : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// "Version 1.530; October 18, 2026" → "1.530"
    public static func shortVersion(_ string: String?) -> String {
        guard let string else { return "未知" }
        guard let range = string.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return string }
        return String(string[range])
    }

    public static func postScriptNames(in url: URL) -> Set<String> {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return Set(descriptors.compactMap { FontMetadataReader.stringAttribute($0, key: kCTFontNameAttribute) })
    }

    private static func versionParts(_ string: String) -> [String]? {
        guard let range = string.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
        return string[range].split(separator: ".").map(String.init)
    }

    /// Reads name ID 5 of the face with this PostScript name in the file.
    public static func versionString(at url: URL, postScriptName: String) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return nil
        }
        let descriptor = descriptors.first {
            FontMetadataReader.stringAttribute($0, key: kCTFontNameAttribute) == postScriptName
        } ?? descriptors.first
        guard let descriptor else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        return CTFontCopyName(font, kCTFontVersionNameKey) as String?
    }
}
