import Foundation

public struct FontNameNormalizationReport: Sendable {
    public let results: [FontNameNormalizationResult]

    public init(results: [FontNameNormalizationResult]) {
        self.results = results
    }

    public var successCount: Int {
        results.filter { $0.status == .success }.count
    }

    public var skippedCount: Int {
        results.filter { $0.status == .skipped }.count
    }

    public var failedCount: Int {
        results.filter { $0.status == .failed }.count
    }

    public var summary: String {
        "规范化完成：成功 \(successCount)，跳过 \(skippedCount)，失败 \(failedCount)"
    }

    public var detailMessage: String {
        let details = results
            .filter { $0.status != .success }
            .prefix(8)
            .map { "\($0.fileURL.lastPathComponent)：\($0.message)" }
            .joined(separator: "\n")
        return details.isEmpty ? summary : "\(summary)\n\(details)"
    }
}

public struct FontNameNormalizationResult: Sendable {
    public let fileURL: URL
    public let status: FontNameNormalizationStatus
    public let targetName: String?
    public let postScriptName: String?
    public let backupURL: URL?
    public let priorPostScriptName: String?
    public let priorFamilyName: String?
    public let message: String

    public init(
        fileURL: URL,
        status: FontNameNormalizationStatus,
        targetName: String?,
        postScriptName: String?,
        backupURL: URL?,
        priorPostScriptName: String? = nil,
        priorFamilyName: String? = nil,
        message: String
    ) {
        self.fileURL = fileURL
        self.status = status
        self.targetName = targetName
        self.postScriptName = postScriptName
        self.backupURL = backupURL
        self.priorPostScriptName = priorPostScriptName
        self.priorFamilyName = priorFamilyName
        self.message = message
    }
}

public enum FontNameNormalizationStatus: Sendable {
    case success
    case skipped
    case failed
}

public struct FontNameNormalizerService: Sendable {
    public init() {}

    public func normalizeFile(at url: URL) -> FontNameNormalizationResult {
        guard !PathUtilities.isFontCopyBackupFile(url) else {
            return skipped(url, "备份文件已跳过")
        }

        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc", "otc"].contains(ext) else {
            return skipped(url, "不是支持的字体格式")
        }

        let targetName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            return failed(url, "文件名为空，无法生成字体名称")
        }

        let priorMetadata = FontMetadataReader.metadata(for: url).first

        do {
            let originalData = try Data(contentsOf: url, options: [.mappedIfSafe])
            let hash = Self.stableShortHash(for: "\(url.standardizedFileURL.path)|\(targetName)")
            let postScriptPrefix = Self.postScriptName(for: targetName, hash: hash)

            let rewrittenData: Data
            let recordedPostScriptName: String

            if ext == "ttc" || ext == "otc" {
                let result = try TTCNameTableRewriter.rewrite(
                    data: originalData,
                    visibleName: targetName,
                    postScriptNamePrefix: postScriptPrefix
                )
                rewrittenData = result.data
                recordedPostScriptName = result.representativePostScriptName
            } else {
                rewrittenData = try SFNTNameTableRewriter.rewrite(
                    data: originalData,
                    visibleName: targetName,
                    postScriptName: postScriptPrefix
                )
                recordedPostScriptName = postScriptPrefix
            }

            try validateFontData(rewrittenData, originalURL: url)
            let backupURL = try createBackup(for: url)
            try rewrittenData.write(to: url, options: .atomic)
            return FontNameNormalizationResult(
                fileURL: url,
                status: .success,
                targetName: targetName,
                postScriptName: recordedPostScriptName,
                backupURL: backupURL,
                priorPostScriptName: priorMetadata?.postScriptName,
                priorFamilyName: priorMetadata?.familyName,
                message: "已写入内部名称“\(targetName)”"
            )
        } catch {
            return failed(url, error.localizedDescription)
        }
    }

    public func normalizeFolder(
        at url: URL,
        progress: ((FontNormalizeProgress) -> Void)? = nil
    ) -> FontNameNormalizationReport {
        let fileURLs: [URL]
        do {
            fileURLs = try collectFontFiles(in: url)
        } catch {
            return FontNameNormalizationReport(results: [failed(url, error.localizedDescription)])
        }

        guard !fileURLs.isEmpty else {
            return FontNameNormalizationReport(results: [skipped(url, "文件夹中没有可处理的字体文件")])
        }

        return normalizeFiles(fileURLs, progress: progress)
    }

    public func normalizeFiles(
        _ urls: [URL],
        progress: ((FontNormalizeProgress) -> Void)? = nil
    ) -> FontNameNormalizationReport {
        var results: [FontNameNormalizationResult] = []
        results.reserveCapacity(urls.count)
        var success = 0
        var skipped = 0
        var failedCount = 0
        let total = urls.count
        progress?(FontNormalizeProgress(
            processed: 0,
            total: total,
            success: 0,
            skipped: 0,
            failed: 0,
            currentName: urls.first?.lastPathComponent
        ))
        for (index, fileURL) in urls.enumerated() {
            progress?(FontNormalizeProgress(
                processed: index,
                total: total,
                success: success,
                skipped: skipped,
                failed: failedCount,
                currentName: fileURL.lastPathComponent
            ))
            let result = normalizeFile(at: fileURL)
            switch result.status {
            case .success: success += 1
            case .skipped: skipped += 1
            case .failed: failedCount += 1
            }
            results.append(result)
            progress?(FontNormalizeProgress(
                processed: index + 1,
                total: total,
                success: success,
                skipped: skipped,
                failed: failedCount,
                currentName: index + 1 < total ? urls[index + 1].lastPathComponent : nil
            ))
        }
        return FontNameNormalizationReport(results: results)
    }

    private func collectFontFiles(in rootURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["ttf", "otf", "ttc", "otc"].contains(ext) else { continue }
            guard !PathUtilities.isFontCopyBackupFile(url) else { continue }
            urls.append(url)
        }
        return urls.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private func validateFontData(_ data: Data, originalURL: URL) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontCopyValidate-\(UUID().uuidString)")
            .appendingPathExtension(originalURL.pathExtension)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard !FontMetadataReader.metadata(for: tempURL).isEmpty else {
            throw FontNameNormalizationError.validationFailed
        }
    }

    private func createBackup(for url: URL) throws -> URL {
        let backupURL = uniqueBackupURL(for: url)
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    private func uniqueBackupURL(for url: URL) -> URL {
        let basePath = url.path + ".bak"
        var candidate = URL(fileURLWithPath: basePath)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: "\(basePath)-\(counter)")
            counter += 1
        }
        return candidate
    }

    private func skipped(_ url: URL, _ message: String) -> FontNameNormalizationResult {
        FontNameNormalizationResult(
            fileURL: url,
            status: .skipped,
            targetName: nil,
            postScriptName: nil,
            backupURL: nil,
            message: message
        )
    }

    private func failed(_ url: URL, _ message: String) -> FontNameNormalizationResult {
        FontNameNormalizationResult(
            fileURL: url,
            status: .failed,
            targetName: nil,
            postScriptName: nil,
            backupURL: nil,
            message: message
        )
    }

    private static func postScriptName(for targetName: String, hash: String) -> String {
        let latin = targetName
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? targetName
        let safe = latin.unicodeScalars
            .map { scalar -> Character in
                Self.isPostScriptSafeASCII(scalar) ? Character(scalar) : "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = safe.isEmpty ? "Font" : String(safe.prefix(40))
        return "FontCopy-\(stem)-\(hash)"
    }

    private static func isPostScriptSafeASCII(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value))
            || (97...122).contains(Int(scalar.value))
            || (48...57).contains(Int(scalar.value))
    }

    private static func stableShortHash(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(String(format: "%010llx", hash).suffix(10))
    }
}

public enum FontNameNormalizationError: LocalizedError, Sendable {
    case unsupportedSFNT
    case unsupportedNameTable
    case missingRequiredTable(String)
    case invalidTable(String)
    case validationFailed
    case stringEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedSFNT:
            return "不是可改写的 TTF/OTF 单字体文件"
        case .unsupportedNameTable:
            return "暂不支持此字体的 name table 格式"
        case .missingRequiredTable(let tag):
            return "缺少必要字体表：\(tag)"
        case .invalidTable(let tag):
            return "字体表结构无效：\(tag)"
        case .validationFailed:
            return "改名后的字体未通过 CoreText 校验"
        case .stringEncodingFailed:
            return "字体名称编码失败"
        }
    }
}

private enum SFNTNameTableRewriter {
    static func rewrite(data: Data, visibleName: String, postScriptName: String) throws -> Data {
        let font = try SFNTFont(data: data)
        guard !font.isCollection else {
            throw FontNameNormalizationError.unsupportedSFNT
        }
        guard font.table(named: "head") != nil else {
            throw FontNameNormalizationError.missingRequiredTable("head")
        }
        guard let nameTable = font.table(named: "name") else {
            throw FontNameNormalizationError.missingRequiredTable("name")
        }

        let rewrittenNameTable = try NameTable(data: nameTable.data)
            .rewritten(visibleName: visibleName, postScriptName: postScriptName)
        return try font.replacingTable(named: "name", with: rewrittenNameTable)
    }
}

struct TTCNormalizationOutput {
    let data: Data
    let representativePostScriptName: String
}

private enum TTCNameTableRewriter {
    static func rewrite(
        data: Data,
        visibleName: String,
        postScriptNamePrefix: String
    ) throws -> TTCNormalizationOutput {
        let header = try TTCHeader(data: data)
        guard !header.subfontOffsets.isEmpty else {
            throw FontNameNormalizationError.unsupportedSFNT
        }

        struct Plan {
            let nameDirectoryEntryOffset: Int
            let newNameTable: Data
            let newPostScriptName: String
            let firstSubfont: Bool
        }

        var plans: [Plan] = []
        var styleSlugCounts: [String: Int] = [:]

        for (index, dirOffset) in header.subfontOffsets.enumerated() {
            let directoryStart = Int(dirOffset)
            guard directoryStart + 12 <= data.count else {
                throw FontNameNormalizationError.unsupportedSFNT
            }
            let sfntVersion = try data.readUInt32(at: directoryStart)
            guard sfntVersion != FourCharCode.ttcf else {
                throw FontNameNormalizationError.unsupportedSFNT
            }
            let numTables = Int(try data.readUInt16(at: directoryStart + 4))
            guard directoryStart + 12 + numTables * 16 <= data.count else {
                throw FontNameNormalizationError.unsupportedSFNT
            }

            var nameEntryOffset: Int?
            var nameTableData: Data?
            for tableIndex in 0..<numTables {
                let entryOffset = directoryStart + 12 + tableIndex * 16
                let tag = try data.readTag(at: entryOffset)
                if tag == "name" {
                    let tableOffset = Int(try data.readUInt32(at: entryOffset + 8))
                    let tableLength = Int(try data.readUInt32(at: entryOffset + 12))
                    guard tableOffset >= 0, tableLength >= 0, tableOffset + tableLength <= data.count else {
                        throw FontNameNormalizationError.invalidTable("name")
                    }
                    nameEntryOffset = entryOffset
                    nameTableData = data.subdata(in: tableOffset..<tableOffset + tableLength)
                    break
                }
            }

            guard let entryOffset = nameEntryOffset, let nameData = nameTableData else {
                throw FontNameNormalizationError.missingRequiredTable("name")
            }

            let parsedNameTable = try NameTable(data: nameData)
            let styleName = parsedNameTable.preferredStyleName() ?? "Regular"
            let baseSlug = sanitizeStyleSlug(styleName) ?? "Style\(index + 1)"
            var slug = baseSlug
            let priorCount = styleSlugCounts[baseSlug, default: 0]
            if priorCount > 0 {
                slug = "\(baseSlug)\(priorCount + 1)"
            }
            styleSlugCounts[baseSlug] = priorCount + 1
            let newPostScriptName = "\(postScriptNamePrefix)-\(slug)"

            let newNameTable = try parsedNameTable.rewritten(
                visibleName: visibleName,
                postScriptName: newPostScriptName
            )
            plans.append(Plan(
                nameDirectoryEntryOffset: entryOffset,
                newNameTable: newNameTable,
                newPostScriptName: newPostScriptName,
                firstSubfont: index == 0
            ))
        }

        var output = data
        for plan in plans {
            while output.count % 4 != 0 {
                output.append(0)
            }
            let newOffset = UInt32(output.count)
            let newLength = UInt32(plan.newNameTable.count)
            output.append(plan.newNameTable)
            let checksum = plan.newNameTable.openTypeChecksum
            output.writeUInt32(checksum, at: plan.nameDirectoryEntryOffset + 4)
            output.writeUInt32(newOffset, at: plan.nameDirectoryEntryOffset + 8)
            output.writeUInt32(newLength, at: plan.nameDirectoryEntryOffset + 12)
        }

        let representative = plans.first?.newPostScriptName ?? postScriptNamePrefix
        return TTCNormalizationOutput(data: output, representativePostScriptName: representative)
    }

    private static func sanitizeStyleSlug(_ styleName: String) -> String? {
        let trimmed = styleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let latin = trimmed
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? trimmed
        var collapsedDash = false
        var slug = ""
        for scalar in latin.unicodeScalars {
            let value = Int(scalar.value)
            let isAllowed = (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
            if isAllowed {
                slug.append(Character(scalar))
                collapsedDash = false
            } else if !collapsedDash {
                slug.append("-")
                collapsedDash = true
            }
        }
        let trimmedSlug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmedSlug.isEmpty ? nil : String(trimmedSlug.prefix(20))
    }
}

private struct TTCHeader {
    let majorVersion: UInt16
    let minorVersion: UInt16
    let subfontOffsets: [UInt32]

    init(data: Data) throws {
        guard data.count >= 12 else { throw FontNameNormalizationError.unsupportedSFNT }
        let tag = try data.readUInt32(at: 0)
        guard tag == FourCharCode.ttcf else {
            throw FontNameNormalizationError.unsupportedSFNT
        }
        majorVersion = try data.readUInt16(at: 4)
        minorVersion = try data.readUInt16(at: 6)
        guard majorVersion == 1 || majorVersion == 2 else {
            throw FontNameNormalizationError.unsupportedSFNT
        }
        let numFonts = Int(try data.readUInt32(at: 8))
        guard numFonts > 0, data.count >= 12 + numFonts * 4 else {
            throw FontNameNormalizationError.unsupportedSFNT
        }
        var offsets: [UInt32] = []
        offsets.reserveCapacity(numFonts)
        for index in 0..<numFonts {
            let offset = try data.readUInt32(at: 12 + index * 4)
            guard Int(offset) >= 12, Int(offset) < data.count else {
                throw FontNameNormalizationError.unsupportedSFNT
            }
            offsets.append(offset)
        }
        subfontOffsets = offsets
    }
}

private struct SFNTFont {
    struct Table {
        let tag: String
        let data: Data
    }

    let sfntVersion: UInt32
    let tables: [Table]

    init(data: Data) throws {
        guard data.count >= 12 else { throw FontNameNormalizationError.unsupportedSFNT }
        sfntVersion = try data.readUInt32(at: 0)
        let numTables = Int(try data.readUInt16(at: 4))
        guard sfntVersion != FourCharCode.ttcf else {
            tables = []
            return
        }
        guard [FourCharCode.trueType, FourCharCode.otto, FourCharCode.trueTag].contains(sfntVersion) else {
            throw FontNameNormalizationError.unsupportedSFNT
        }
        guard data.count >= 12 + numTables * 16 else {
            throw FontNameNormalizationError.unsupportedSFNT
        }

        var parsedTables: [Table] = []
        for index in 0..<numTables {
            let recordOffset = 12 + index * 16
            let tag = try data.readTag(at: recordOffset)
            let offset = Int(try data.readUInt32(at: recordOffset + 8))
            let length = Int(try data.readUInt32(at: recordOffset + 12))
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw FontNameNormalizationError.invalidTable(tag)
            }
            parsedTables.append(Table(tag: tag, data: data.subdata(in: offset..<offset + length)))
        }
        tables = parsedTables
    }

    var isCollection: Bool {
        sfntVersion == FourCharCode.ttcf
    }

    func table(named tag: String) -> Table? {
        tables.first { $0.tag == tag }
    }

    func replacingTable(named targetTag: String, with replacement: Data) throws -> Data {
        let updatedTables = tables.map { table in
            table.tag == targetTag ? Table(tag: table.tag, data: replacement) : table
        }
        guard updatedTables.contains(where: { $0.tag == "head" }) else {
            throw FontNameNormalizationError.missingRequiredTable("head")
        }

        var output = Data()
        let sortedTables = updatedTables.sorted { $0.tag < $1.tag }
        let numTables = UInt16(sortedTables.count)
        let metrics = SFNTDirectoryMetrics(numTables: numTables)

        output.appendUInt32(sfntVersion)
        output.appendUInt16(numTables)
        output.appendUInt16(metrics.searchRange)
        output.appendUInt16(metrics.entrySelector)
        output.appendUInt16(metrics.rangeShift)

        var tablePayloads: [(tag: String, checksum: UInt32, offset: UInt32, length: UInt32, data: Data)] = []
        var payloadOffset = 12 + sortedTables.count * 16
        for table in sortedTables {
            var tableData = table.data
            if table.tag == "head", tableData.count >= 12 {
                tableData.writeUInt32(0, at: 8)
            }
            let alignedOffset = payloadOffset.alignedTo4
            payloadOffset = alignedOffset + tableData.count.alignedTo4
            tablePayloads.append((
                tag: table.tag,
                checksum: tableData.openTypeChecksum,
                offset: UInt32(alignedOffset),
                length: UInt32(tableData.count),
                data: tableData
            ))
        }

        for payload in tablePayloads {
            output.appendTag(payload.tag)
            output.appendUInt32(payload.checksum)
            output.appendUInt32(payload.offset)
            output.appendUInt32(payload.length)
        }

        for payload in tablePayloads {
            while output.count < Int(payload.offset) {
                output.append(0)
            }
            output.append(payload.data)
            output.appendPaddingTo4ByteBoundary()
        }

        guard let headPayload = tablePayloads.first(where: { $0.tag == "head" }) else {
            throw FontNameNormalizationError.missingRequiredTable("head")
        }
        let checksumAdjustment = 0xB1B0AFBA &- output.openTypeChecksum
        output.writeUInt32(checksumAdjustment, at: Int(headPayload.offset) + 8)
        return output
    }
}

private struct SFNTDirectoryMetrics {
    let searchRange: UInt16
    let entrySelector: UInt16
    let rangeShift: UInt16

    init(numTables: UInt16) {
        var maxPower: UInt16 = 1
        var selector: UInt16 = 0
        while maxPower * 2 <= numTables {
            maxPower *= 2
            selector += 1
        }
        searchRange = maxPower * 16
        entrySelector = selector
        rangeShift = numTables * 16 - searchRange
    }
}

private struct NameTable {
    struct Record: Hashable {
        let platformID: UInt16
        let encodingID: UInt16
        let languageID: UInt16
        let nameID: UInt16
        let rawString: Data

        var key: RecordKey {
            RecordKey(platformID: platformID, encodingID: encodingID, languageID: languageID, nameID: nameID)
        }
    }

    struct RecordKey: Hashable, Comparable {
        let platformID: UInt16
        let encodingID: UInt16
        let languageID: UInt16
        let nameID: UInt16

        static func < (lhs: RecordKey, rhs: RecordKey) -> Bool {
            if lhs.platformID != rhs.platformID { return lhs.platformID < rhs.platformID }
            if lhs.encodingID != rhs.encodingID { return lhs.encodingID < rhs.encodingID }
            if lhs.languageID != rhs.languageID { return lhs.languageID < rhs.languageID }
            return lhs.nameID < rhs.nameID
        }
    }

    let format: UInt16
    let records: [Record]

    init(data: Data) throws {
        guard data.count >= 6 else { throw FontNameNormalizationError.invalidTable("name") }
        format = try data.readUInt16(at: 0)
        guard format == 0 || format == 1 else { throw FontNameNormalizationError.unsupportedNameTable }
        let count = Int(try data.readUInt16(at: 2))
        let stringOffset = Int(try data.readUInt16(at: 4))
        guard data.count >= 6 + count * 12, stringOffset <= data.count else {
            throw FontNameNormalizationError.invalidTable("name")
        }

        var parsedRecords: [Record] = []
        for index in 0..<count {
            let offset = 6 + index * 12
            let platformID = try data.readUInt16(at: offset)
            let encodingID = try data.readUInt16(at: offset + 2)
            let languageID = try data.readUInt16(at: offset + 4)
            let nameID = try data.readUInt16(at: offset + 6)
            let length = Int(try data.readUInt16(at: offset + 8))
            let stringRecordOffset = Int(try data.readUInt16(at: offset + 10))
            let start = stringOffset + stringRecordOffset
            guard start >= stringOffset, start + length <= data.count else {
                continue
            }
            parsedRecords.append(Record(
                platformID: platformID,
                encodingID: encodingID,
                languageID: languageID,
                nameID: nameID,
                rawString: data.subdata(in: start..<start + length)
            ))
        }
        records = parsedRecords
    }

    func rewritten(visibleName: String, postScriptName: String) throws -> Data {
        let styleName = preferredStyleName() ?? "Regular"
        let replacements = NameReplacements(
            visibleName: visibleName,
            styleName: styleName,
            postScriptName: postScriptName
        )

        var outputRecords: [RecordKey: Data] = [:]
        for record in records {
            if let replacement = replacements.string(for: record.nameID) {
                guard let encoded = Self.encode(replacement, platformID: record.platformID, encodingID: record.encodingID) else {
                    continue
                }
                outputRecords[record.key] = encoded
            } else {
                outputRecords[record.key] = record.rawString
            }
        }

        for required in Self.requiredRecords {
            if outputRecords[required] == nil, let replacement = replacements.string(for: required.nameID) {
                guard let encoded = Self.encode(replacement, platformID: required.platformID, encodingID: required.encodingID) else {
                    throw FontNameNormalizationError.stringEncodingFailed
                }
                outputRecords[required] = encoded
            }
        }

        let sortedKeys = outputRecords.keys.sorted()
        var stringStorage = Data()
        var encodedRecords: [(key: RecordKey, length: UInt16, offset: UInt16)] = []
        for key in sortedKeys {
            guard let rawString = outputRecords[key] else { continue }
            guard rawString.count <= UInt16.max, stringStorage.count <= UInt16.max else {
                throw FontNameNormalizationError.invalidTable("name")
            }
            encodedRecords.append((key: key, length: UInt16(rawString.count), offset: UInt16(stringStorage.count)))
            stringStorage.append(rawString)
        }

        var output = Data()
        output.appendUInt16(0)
        output.appendUInt16(UInt16(encodedRecords.count))
        output.appendUInt16(UInt16(6 + encodedRecords.count * 12))
        for record in encodedRecords {
            output.appendUInt16(record.key.platformID)
            output.appendUInt16(record.key.encodingID)
            output.appendUInt16(record.key.languageID)
            output.appendUInt16(record.key.nameID)
            output.appendUInt16(record.length)
            output.appendUInt16(record.offset)
        }
        output.append(stringStorage)
        return output
    }

    func preferredStyleName() -> String? {
        for nameID in [17, 2] as [UInt16] {
            for record in records where record.nameID == nameID {
                if let decoded = Self.decode(record.rawString, platformID: record.platformID, encodingID: record.encodingID),
                   !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static let requiredRecords: [RecordKey] = {
        let nameIDs: [UInt16] = [1, 2, 3, 4, 6, 16, 17]
        let windowsLanguages: [UInt16] = [0x0409, 0x0804]
        let windowsRecords = windowsLanguages.flatMap { languageID in
            nameIDs.map { nameID in
                RecordKey(platformID: 3, encodingID: 1, languageID: languageID, nameID: nameID)
            }
        }
        let unicodeRecords = nameIDs.map { nameID in
            RecordKey(platformID: 0, encodingID: 3, languageID: 0, nameID: nameID)
        }
        return windowsRecords + unicodeRecords
    }()

    private static func decode(_ data: Data, platformID: UInt16, encodingID: UInt16) -> String? {
        if platformID == 0 || platformID == 3 {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if platformID == 1 {
            return String(data: data, encoding: .macOSRoman)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func encode(_ string: String, platformID: UInt16, encodingID: UInt16) -> Data? {
        if platformID == 0 || platformID == 3 {
            return string.data(using: .utf16BigEndian)
        }
        if platformID == 1 {
            return string.data(using: .macOSRoman)
        }
        return string.data(using: .utf8)
    }
}

private struct NameReplacements {
    let visibleName: String
    let styleName: String
    let postScriptName: String

    func string(for nameID: UInt16) -> String? {
        switch nameID {
        case 1, 16, 18, 21:
            return visibleName
        case 4:
            return fullName
        case 2, 17, 22:
            return styleName
        case 3:
            return "\(fullName); \(postScriptName)"
        case 6:
            return postScriptName
        default:
            return nil
        }
    }

    private var fullName: String {
        let normalizedStyle = styleName.lowercased()
        if normalizedStyle == "regular" || normalizedStyle.isEmpty {
            return visibleName
        }
        if visibleName.lowercased().contains(normalizedStyle) {
            return visibleName
        }
        return "\(visibleName) \(styleName)"
    }
}

private enum FourCharCode {
    static let trueType: UInt32 = 0x00010000
    static let otto: UInt32 = 0x4F54544F
    static let trueTag: UInt32 = 0x74727565
    static let ttcf: UInt32 = 0x74746366
}

private extension Int {
    var alignedTo4: Int {
        (self + 3) & ~3
    }
}

private extension Data {
    func readUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw FontNameNormalizationError.unsupportedSFNT }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw FontNameNormalizationError.unsupportedSFNT }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func readTag(at offset: Int) throws -> String {
        guard offset >= 0, offset + 4 <= count else { throw FontNameNormalizationError.unsupportedSFNT }
        return String(bytes: self[offset..<offset + 4], encoding: .ascii) ?? "????"
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        guard offset >= 0, offset + 4 <= count else { return }
        self[offset] = UInt8((value >> 24) & 0xff)
        self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff)
        self[offset + 3] = UInt8(value & 0xff)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendTag(_ tag: String) {
        let bytes = Array(tag.utf8.prefix(4))
        append(contentsOf: bytes)
        if bytes.count < 4 {
            append(contentsOf: Array(repeating: 0, count: 4 - bytes.count))
        }
    }

    mutating func appendPaddingTo4ByteBoundary() {
        while count % 4 != 0 {
            append(0)
        }
    }

    var openTypeChecksum: UInt32 {
        var checksum: UInt32 = 0
        var offset = 0
        while offset < count {
            var value: UInt32 = 0
            for byteIndex in 0..<4 {
                value <<= 8
                if offset + byteIndex < count {
                    value |= UInt32(self[offset + byteIndex])
                }
            }
            checksum = checksum &+ value
            offset += 4
        }
        return checksum
    }
}
