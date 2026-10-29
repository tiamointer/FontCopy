import CoreText
import Foundation

public struct FontScannerService: Sendable {
    public init() {}

    private struct FileEntry: Sendable {
        let url: URL
        let relativePath: String
        let category: String
        let ext: String
        let fileSize: Int64
        let modifiedAt: Double
        let isSupported: Bool
    }

    public func scanFolder(
        at rootURL: URL,
        favorites: Set<String>,
        compared: Set<String>,
        cachedEntries: [String: CachedFontEntry] = [:],
        forceFullRescan: Bool = false,
        progress: ((FontScanProgress) -> Void)? = nil,
        onPartial: (([FontItem]) -> Void)? = nil
    ) throws -> FontScanResult {
        // 已安装字体快照较慢（枚举系统所有字体），与目录遍历并行，
        // 不再串行阻塞，扫描进度可更快出现。
        final class SnapshotBox: @unchecked Sendable { var value = InstalledFontSnapshot(postScriptNames: [], fileHashesByPostScriptName: [:]) }
        let snapshotBox = SnapshotBox()
        let snapshotGroup = DispatchGroup()
        snapshotGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            snapshotBox.value = InstalledFontService().snapshot()
            snapshotGroup.leave()
        }

        let files = try collectFontFiles(in: rootURL)
        let total = files.count
        progress?(FontScanProgress(processed: 0, total: total, currentPath: nil))

        // Pass 1（并行）：取元数据——命中缓存直接用，未命中才调 CoreText。
        final class Accumulator: @unchecked Sendable {
            let lock = NSLock()
            var fonts: [(file: FileEntry, meta: [FontMetadata], cachedHash: String?)] = []
            var skipped: [SkippedFontFile] = []
            var processed = 0
        }
        let acc = Accumulator()

        files.withUnsafeBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: buffer.count) { index in
                let file = buffer[index]
                defer {
                    acc.lock.lock()
                    acc.processed += 1
                    let p = acc.processed
                    acc.lock.unlock()
                    progress?(FontScanProgress(processed: p, total: total, currentPath: file.relativePath))
                }

                if !file.isSupported {
                    let fallback = file.url.deletingPathExtension().lastPathComponent
                    let meta = FontMetadata(postScriptName: fallback, familyName: fallback,
                                            styleName: nil, displayName: file.url.lastPathComponent, version: nil)
                    acc.lock.lock(); acc.fonts.append((file, [meta], "")); acc.lock.unlock()
                    return
                }

                if !forceFullRescan,
                   let cached = cachedEntries[file.relativePath],
                   cached.fileSize == file.fileSize,
                   cached.modifiedAt == file.modifiedAt,
                   !cached.isUnsupported,
                   cached.metadata.allSatisfy({ $0.scriptSupport != nil }) {
                    let meta = cached.metadata.map {
                        FontMetadata(postScriptName: $0.postScriptName, familyName: $0.familyName,
                                     styleName: $0.styleName, displayName: $0.displayName, version: $0.version,
                                     scriptSupport: $0.scriptSupport)
                    }
                    acc.lock.lock(); acc.fonts.append((file, meta, cached.fileHash)); acc.lock.unlock()
                    return
                }

                registerForProcessPreview(file.url)
                let meta = FontMetadataReader.metadata(for: file.url)
                if meta.isEmpty {
                    acc.lock.lock()
                    acc.skipped.append(SkippedFontFile(path: file.relativePath, reason: "CoreText 无法解析字体元数据"))
                    acc.lock.unlock()
                    return
                }
                acc.lock.lock(); acc.fonts.append((file, meta, nil)); acc.lock.unlock()
            }
        }

        // 列表/预览无需等待已安装快照：先用临时状态(.missing)立即交付列表，
        // 安装徽标随后由 Pass2 的结果补正。
        if let onPartial {
            var provisional: [FontItem] = []
            for (file, meta, _) in acc.fonts {
                for m in meta {
                    provisional.append(FontItem(
                        fileID: UUID(), sourceURL: file.url, relativePath: file.relativePath,
                        displayName: m.displayName, postScriptName: m.postScriptName, familyName: m.familyName,
                        styleName: m.styleName, version: m.version, fileHash: "",
                        category: file.category,
                        installStatus: file.isSupported ? .missing : .unsupported,
                        isFavorite: favorites.contains(m.postScriptName), isCompared: compared.contains(m.postScriptName),
                        scriptSupport: scriptSupport(file, m)
                    ))
                }
            }
            provisional.sort { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
            onPartial(provisional)
        }

        snapshotGroup.wait()
        let snapshot = snapshotBox.value

        // Pass 2：仅对“PostScript 名确实已安装”的字体才读全文件算 hash（少数），
        // 未安装的占绝大多数，直接跳过——这是去掉全库哈希后的主要提速点。
        var fonts: [FontItem] = []
        var cacheOut: [String: CachedFontEntry] = [:]
        var installedHashMemo: [URL: String] = [:]
        for (file, meta, cachedHash) in acc.fonts {
            if !file.isSupported {
                let m = meta[0]
                fonts.append(FontItem(
                    fileID: UUID(), sourceURL: file.url, relativePath: file.relativePath,
                    displayName: m.displayName, postScriptName: m.postScriptName, familyName: m.familyName,
                    styleName: m.styleName, version: m.version, fileHash: "",
                    category: file.category, installStatus: .unsupported,
                    isFavorite: favorites.contains(m.postScriptName), isCompared: compared.contains(m.postScriptName)
                ))
                cacheOut[file.relativePath] = CachedFontEntry(
                    relativePath: file.relativePath, fileSize: file.fileSize, modifiedAt: file.modifiedAt,
                    fileHash: "", isUnsupported: true,
                    metadata: meta.map { CachedFontMetadata(postScriptName: $0.postScriptName, familyName: $0.familyName, styleName: $0.styleName, displayName: $0.displayName, version: $0.version, scriptSupport: $0.scriptSupport ?? []) }
                )
                continue
            }

            let anyInstalled = meta.contains { snapshot.postScriptNames.contains($0.postScriptName) }
            let hash: String
            if let cachedHash, !cachedHash.isEmpty {
                hash = cachedHash
            } else if anyInstalled {
                hash = (try? FileHash.sha256Hex(for: file.url)) ?? ""
            } else {
                hash = ""
            }

            let fileID = UUID()
            for m in meta {
                let status = resolveStatus(
                    postScriptName: m.postScriptName, fileHash: hash,
                    snapshot: snapshot, memo: &installedHashMemo
                )
                fonts.append(FontItem(
                    fileID: fileID, sourceURL: file.url, relativePath: file.relativePath,
                    displayName: m.displayName, postScriptName: m.postScriptName, familyName: m.familyName,
                    styleName: m.styleName, version: m.version, fileHash: hash,
                    category: file.category, installStatus: status,
                    isFavorite: favorites.contains(m.postScriptName), isCompared: compared.contains(m.postScriptName),
                    scriptSupport: scriptSupport(file, m)
                ))
            }
            cacheOut[file.relativePath] = CachedFontEntry(
                relativePath: file.relativePath, fileSize: file.fileSize, modifiedAt: file.modifiedAt,
                fileHash: hash, isUnsupported: false,
                metadata: meta.map { CachedFontMetadata(postScriptName: $0.postScriptName, familyName: $0.familyName, styleName: $0.styleName, displayName: $0.displayName, version: $0.version, scriptSupport: $0.scriptSupport ?? []) }
            )
        }

        return FontScanResult(
            fonts: fonts.sorted {
                $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
            },
            skipped: acc.skipped,
            cacheEntries: cacheOut
        )
    }

    private func collectFontFiles(in rootURL: URL) throws -> [FileEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var entries: [FileEntry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard !PathUtilities.isFontCopyBackupFile(url) else { continue }
            let ext = url.pathExtension.lowercased()
            guard FontItem.fontLikeExtensions.contains(ext) else { continue }
            let relativePath = PathUtilities.relativePath(for: url, rootURL: rootURL)
            entries.append(FileEntry(
                url: url,
                relativePath: relativePath,
                category: PathUtilities.category(for: relativePath),
                ext: ext,
                fileSize: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
                isSupported: FontItem.supportedExtensions.contains(ext)
            ))
        }
        return entries
    }

    private func scriptSupport(_ file: FileEntry, _ meta: FontMetadata) -> FontScriptSupport {
        FontScriptSupport.resolve(
            measured: meta.scriptSupport ?? [],
            names: [file.url.deletingPathExtension().lastPathComponent, meta.familyName]
        )
    }

    private func registerForProcessPreview(_ url: URL) {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }

    // 按需冲突判定：仅当库内字体与已安装字体同名、且我们已有库内文件 hash 时，
    // 才去哈希那少数几个对应的已安装文件（memo 避免重复读），其余直接返回。
    private func resolveStatus(
        postScriptName: String,
        fileHash: String,
        snapshot: InstalledFontSnapshot,
        memo: inout [URL: String]
    ) -> FontInstallStatus {
        guard snapshot.postScriptNames.contains(postScriptName) else { return .missing }
        guard !fileHash.isEmpty else { return .installed }

        guard let installedURLs = snapshot.urlsByPostScriptName[postScriptName], !installedURLs.isEmpty else {
            return .installed
        }
        var installedHashes: Set<String> = []
        for url in installedURLs {
            if let h = memo[url] {
                if !h.isEmpty { installedHashes.insert(h) }
            } else {
                let h = (try? FileHash.sha256Hex(for: url)) ?? ""
                memo[url] = h
                if !h.isEmpty { installedHashes.insert(h) }
            }
        }
        if !installedHashes.isEmpty, !installedHashes.contains(fileHash) {
            return .conflict
        }
        return .installed
    }
}
