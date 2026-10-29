import Foundation

/// Fonts shown as one card: the weights of one family, folded together.
///
/// Normalized libraries give every weight its own family name (the file name),
/// so families are recovered from file names: files in the same folder named
/// `<base>-<weight>` belong together when at least two of them share `<base>`.
public struct FontFamilyGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Ordered from lightest to heaviest.
    public let members: [FontItem]
    /// Weight label of each member, parallel to `members`.
    public let weightNames: [String]

    public var isFamily: Bool { members.count > 1 }

    /// The member closest to a regular weight, used as the card's default face.
    public var representativeIndex: Int {
        let ranks = weightNames.map { FontFamilyGrouping.weightRank($0) ?? Int.max }
        let target = FontFamilyGrouping.regularRank
        return ranks.indices.min { abs(ranks[$0] - target) < abs(ranks[$1] - target) } ?? 0
    }

    public static func single(_ font: FontItem) -> FontFamilyGroup {
        FontFamilyGroup(id: font.id.uuidString, name: font.displayName, members: [font], weightNames: [font.styleName ?? ""])
    }
}

public enum FontFamilyGrouping {
    static let regularRank = 60

    /// Weight words used in file names, with a lightness rank.
    private static let weightRanks: [String: Int] = [
        "极细": 0, "特细": 10, "超细": 10, "纤细": 10, "细体": 30, "细": 30, "半细": 40,
        "标准": 50, "常规": 60, "正常": 60, "中等": 70, "中": 70, "半粗": 80,
        "粗体": 90, "粗": 90, "加粗": 100, "特粗": 110, "重": 110, "超粗": 120, "黑": 120,
        "hairline": 0, "thin": 0, "extralight": 10, "ultralight": 10, "light": 30,
        "semilight": 40, "demilight": 40, "normal": 50, "book": 50, "regular": 60,
        "medium": 70, "semibold": 80, "demibold": 80, "bold": 90, "extrabold": 100,
        "ultrabold": 100, "heavy": 110, "black": 120,
        "w1": 0, "w2": 10, "w3": 30, "w4": 60, "w5": 70, "w6": 80, "w7": 90, "w8": 100, "w9": 120,
        "w01": 0, "w02": 10, "w03": 30, "w04": 60, "w05": 70, "w06": 80, "w07": 90, "w08": 100, "w09": 120,
        "l": 30, "r": 60, "m": 70, "s": 80, "b": 90, "e": 100, "h": 110
    ]

    public static func weightRank(_ weight: String) -> Int? {
        let lowered = weight.lowercased()
        if let rank = weightRanks[lowered] { return rank }
        // Numeric weights: CSS-style "100W"/"400" (江城系列), or stroke codes like "W35".
        if lowered.range(of: #"^[1-9]00w?$"#, options: .regularExpression) != nil,
           let digit = lowered.first?.wholeNumberValue {
            return [0, 10, 30, 60, 70, 80, 90, 100, 120][digit - 1]
        }
        if lowered.range(of: #"^w[1-9][0-9]$"#, options: .regularExpression) != nil {
            return Int(lowered.dropFirst())
        }
        return nil
    }

    /// Script tags stay separate cards; the 简繁 filter handles them.
    private static let scriptTags: Set<String> = ["sc", "tc", "hk", "tw", "简", "繁", "简体", "繁体", "简繁"]

    /// Weight words recognised when glued to the name without a separator (`白无常可可体常规`).
    private static let gluedWords: [String] = {
        // Skip codes too short to be safe glued on (`b`, `w4`); single CJK weights are listed below.
        let words = weightRanks.keys.filter { $0.count >= ($0.allSatisfy(\.isASCII) ? 3 : 2) }
        return (words + ["粗", "细", "中", "重", "斜体", "italic"]).sorted { $0.count > $1.count }
    }()

    /// Splits a file stem into family base and the weight or style that tells members apart:
    /// `未来荧黑简体-常规`, `点点像素体-圆形`, `江城正义体 400W`, `仓耳非白W03`, `白无常可可体粗`.
    public static func split(stem: String) -> (base: String, weight: String)? {
        let stem = stem.trimmingCharacters(in: .whitespaces)
        if let mark = stem.lastIndex(where: { $0 == "-" || $0 == "_" || $0 == " " }) {
            let base = String(stem[..<mark]).trimmingCharacters(in: .whitespaces)
            let suffix = String(stem[stem.index(after: mark)...])
            if !base.isEmpty, !suffix.isEmpty, !scriptTags.contains(suffix.lowercased()),
               stem[mark] != " " || weightRank(suffix) != nil {
                return (base, suffix)
            }
        }
        let lowered = stem.lowercased()
        if let word = gluedWords.first(where: { lowered.hasSuffix($0) && lowered.count > $0.count })
            ?? lowered.range(of: #"(w[0-9]{2}|[1-9]00w)$"#, options: .regularExpression).map({ String(lowered[$0]) }) {
            let base = String(stem.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { return (base, String(stem.suffix(word.count))) }
        }
        return nil
    }

    /// Groups fonts while keeping the order in which each group first appears.
    /// A file named exactly like a family base (`未来荧黑` next to `未来荧黑-常规`) joins that family.
    public static func group(_ fonts: [FontItem]) -> [FontFamilyGroup] {
        func folderAndStem(_ font: FontItem) -> (folder: String, stem: String) {
            let path = font.relativePath as NSString
            let stem = (path.lastPathComponent as NSString).deletingPathExtension
            return (path.deletingLastPathComponent, stem.trimmingCharacters(in: .whitespaces))
        }

        var splits: [(key: String, base: String, label: String)?] = []
        var splitFiles: [String: Set<UUID>] = [:]
        for font in fonts {
            let location = folderAndStem(font)
            if let parts = split(stem: location.stem) {
                let key = location.folder + "/" + parts.base
                splits.append((key, parts.base, parts.weight))
                splitFiles[key, default: []].insert(font.fileID)
            } else {
                splits.append(nil)
            }
        }

        var assignments: [(key: String, label: String)?] = []
        var memberFiles: [String: Set<UUID>] = [:]
        for (font, split) in zip(fonts, splits) {
            let location = folderAndStem(font)
            let bareKey = location.folder + "/" + location.stem
            if let split, (splitFiles[split.key]?.count ?? 0) > 1 {
                assignments.append((split.key, split.label))
                memberFiles[split.key, default: []].insert(font.fileID)
            } else if splitFiles[bareKey] != nil {
                assignments.append((bareKey, font.styleName ?? "默认"))
                memberFiles[bareKey, default: []].insert(font.fileID)
            } else if let split {
                assignments.append((split.key, split.label))
                memberFiles[split.key, default: []].insert(font.fileID)
            } else {
                assignments.append(nil)
            }
        }

        var names: [String: String] = [:]
        for split in splits.compactMap({ $0 }) { names[split.key] = split.base }

        var order: [String] = []
        var buckets: [String: [(font: FontItem, label: String)]] = [:]
        for (font, assignment) in zip(fonts, assignments) {
            let groupID: String
            let label: String
            if let assignment, (memberFiles[assignment.key]?.count ?? 0) > 1 {
                (groupID, label) = (assignment.key, assignment.label)
            } else {
                (groupID, label) = (font.id.uuidString, font.styleName ?? "")
            }
            if buckets[groupID] == nil { order.append(groupID) }
            buckets[groupID, default: []].append((font, label))
        }

        return order.map { groupID in
            let entries = buckets[groupID]!
            guard entries.count > 1 else { return .single(entries[0].font) }
            let sorted = entries.enumerated().sorted { lhs, rhs in
                let l = weightRank(lhs.element.label) ?? Int.max
                let r = weightRank(rhs.element.label) ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }.map(\.element)
            return FontFamilyGroup(
                id: groupID,
                name: names[groupID] ?? sorted[0].font.familyName,
                members: sorted.map(\.font),
                weightNames: distinctLabels(sorted)
            )
        }
    }

    /// Repeated labels (the same weight as .ttf and .ttc, or faces of one collection) get the
    /// file type and a counter so every popup entry can be told apart.
    private static func distinctLabels(_ entries: [(font: FontItem, label: String)]) -> [String] {
        let counts = Dictionary(entries.map { ($0.label, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        return entries.map { entry in
            guard counts[entry.label, default: 0] > 1 else { return entry.label }
            let labelled = "\(entry.label) · \(entry.font.fileExtension)"
            seen[labelled, default: 0] += 1
            let repeats = entries.filter { $0.label == entry.label && $0.font.fileExtension == entry.font.fileExtension }.count
            return repeats > 1 ? "\(labelled) \(seen[labelled]!)" : labelled
        }
    }
}
