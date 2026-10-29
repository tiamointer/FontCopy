import Foundation

/// A nameID referenced by fvar/STAT that has no usable record in the name table.
/// Apps such as After Effects refuse to launch when a variable font installed in
/// /Library/Fonts points its named instances at missing names.
public struct DanglingNameReference: Sendable, Hashable {
    public let table: String
    public let nameID: UInt16
    public let context: String
}

public enum FontNameReferenceValidator {
    public static func danglingReferences(at url: URL) throws -> [DanglingNameReference] {
        try danglingReferences(in: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    /// Checks every subfont (TTC/OTC included) and returns the referenced nameIDs
    /// that the font's name table does not provide.
    public static func danglingReferences(in data: Data) throws -> [DanglingNameReference] {
        var result: [DanglingNameReference] = []
        for directoryOffset in try subfontDirectoryOffsets(in: data) {
            let tables = try tableDirectory(in: data, at: directoryOffset)
            let references = try nameReferences(in: data, tables: tables)
            guard !references.isEmpty else { continue }
            let available = try availableNameIDs(in: data, tables: tables)
            for reference in references where !available.contains(reference.nameID) {
                if !result.contains(reference) {
                    result.append(reference)
                }
            }
        }
        return result
    }

    public static func describe(_ references: [DanglingNameReference]) -> String {
        let ids = references.map { "\($0.nameID)(\($0.table) \($0.context))" }
        return "字体的 fvar/STAT 引用了 name 表中不存在的名称：\(ids.joined(separator: ", "))"
    }

    private typealias TableRange = Range<Int>

    private static func subfontDirectoryOffsets(in data: Data) throws -> [Int] {
        guard data.count >= 12 else { throw FontNameNormalizationError.unsupportedSFNT }
        guard try data.fcUInt32(at: 0) == 0x74746366 else { return [0] }
        let numFonts = Int(try data.fcUInt32(at: 8))
        return try (0..<numFonts).map { Int(try data.fcUInt32(at: 12 + $0 * 4)) }
    }

    private static func tableDirectory(in data: Data, at directoryOffset: Int) throws -> [String: TableRange] {
        let numTables = Int(try data.fcUInt16(at: directoryOffset + 4))
        var tables: [String: TableRange] = [:]
        for index in 0..<numTables {
            let entry = directoryOffset + 12 + index * 16
            guard entry + 16 <= data.count else { throw FontNameNormalizationError.unsupportedSFNT }
            let tag = String(bytes: data[entry..<entry + 4], encoding: .ascii) ?? "????"
            let offset = Int(try data.fcUInt32(at: entry + 8))
            let length = Int(try data.fcUInt32(at: entry + 12))
            guard offset + length <= data.count else { throw FontNameNormalizationError.invalidTable(tag) }
            tables[tag] = offset..<offset + length
        }
        return tables
    }

    private static func nameReferences(in data: Data, tables: [String: TableRange]) throws -> [DanglingNameReference] {
        var references: [DanglingNameReference] = []
        func add(_ table: String, _ nameID: UInt16, _ context: String) {
            // 0xFFFF means "no name".
            guard nameID != 0xFFFF else { return }
            references.append(DanglingNameReference(table: table, nameID: nameID, context: context))
        }

        if let fvar = tables["fvar"] {
            let base = fvar.lowerBound
            let axesOffset = Int(try data.fcUInt16(at: base + 4))
            let axisCount = Int(try data.fcUInt16(at: base + 8))
            let axisSize = Int(try data.fcUInt16(at: base + 10))
            let instanceCount = Int(try data.fcUInt16(at: base + 12))
            let instanceSize = Int(try data.fcUInt16(at: base + 14))
            for axis in 0..<axisCount {
                let record = base + axesOffset + axis * axisSize
                add("fvar", try data.fcUInt16(at: record + 18), "axis \(axis)")
            }
            let instancesStart = base + axesOffset + axisCount * axisSize
            let hasPostScriptNameID = instanceSize >= axisCount * 4 + 6
            for instance in 0..<instanceCount {
                let record = instancesStart + instance * instanceSize
                add("fvar", try data.fcUInt16(at: record), "instance \(instance) subfamily")
                if hasPostScriptNameID {
                    add("fvar", try data.fcUInt16(at: record + 4 + axisCount * 4), "instance \(instance) postscript")
                }
            }
        }

        if let stat = tables["STAT"] {
            let base = stat.lowerBound
            let minorVersion = try data.fcUInt16(at: base + 2)
            let designAxisSize = Int(try data.fcUInt16(at: base + 4))
            let designAxisCount = Int(try data.fcUInt16(at: base + 6))
            let designAxesOffset = Int(try data.fcUInt32(at: base + 8))
            let axisValueCount = Int(try data.fcUInt16(at: base + 12))
            let axisValuesOffset = Int(try data.fcUInt32(at: base + 14))
            for axis in 0..<designAxisCount {
                add("STAT", try data.fcUInt16(at: base + designAxesOffset + axis * designAxisSize + 4), "axis \(axis)")
            }
            let valueOffsetsStart = base + axisValuesOffset
            for value in 0..<axisValueCount {
                let valueTable = valueOffsetsStart + Int(try data.fcUInt16(at: valueOffsetsStart + value * 2))
                // Every AxisValue format (1-4) stores valueNameID at offset 6.
                add("STAT", try data.fcUInt16(at: valueTable + 6), "axis value \(value)")
            }
            if minorVersion >= 1 {
                add("STAT", try data.fcUInt16(at: base + 18), "elided fallback")
            }
        }
        return references
    }

    /// nameIDs with a Unicode/Windows record; Mac-only records count only when the
    /// font has no Unicode/Windows records at all.
    private static func availableNameIDs(in data: Data, tables: [String: TableRange]) throws -> Set<UInt16> {
        guard let name = tables["name"] else { return [] }
        let base = name.lowerBound
        let count = Int(try data.fcUInt16(at: base + 2))
        var unicodeIDs: Set<UInt16> = []
        var otherIDs: Set<UInt16> = []
        for index in 0..<count {
            let record = base + 6 + index * 12
            let platformID = try data.fcUInt16(at: record)
            let nameID = try data.fcUInt16(at: record + 6)
            if platformID == 0 || platformID == 3 {
                unicodeIDs.insert(nameID)
            } else {
                otherIDs.insert(nameID)
            }
        }
        return unicodeIDs.isEmpty ? otherIDs : unicodeIDs
    }
}

private extension Data {
    func fcUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw FontNameNormalizationError.invalidTable("fvar/STAT/name") }
        return (UInt16(self[startIndex + offset]) << 8) | UInt16(self[startIndex + offset + 1])
    }

    func fcUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw FontNameNormalizationError.invalidTable("fvar/STAT/name") }
        return (UInt32(try fcUInt16(at: offset)) << 16) | UInt32(try fcUInt16(at: offset + 2))
    }
}
