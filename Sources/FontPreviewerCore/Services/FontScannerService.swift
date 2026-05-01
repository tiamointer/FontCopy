import CoreText
import Foundation

public struct FontScannerService: Sendable {
    public init() {}

    public func scanFolder(
        at rootURL: URL,
        favorites: Set<String>,
        compared: Set<String>
    ) throws -> FontScanResult {
        let installedSnapshot = InstalledFontService().snapshot()
        let fileURLs = try collectFontFiles(in: rootURL)
        var fonts: [FontItem] = []
        var skipped: [SkippedFontFile] = []

        for fileURL in fileURLs {
            let ext = fileURL.pathExtension.lowercased()
            let relativePath = PathUtilities.relativePath(for: fileURL, rootURL: rootURL)
            let category = PathUtilities.category(for: relativePath)
            let fileID = UUID()

            guard FontItem.supportedExtensions.contains(ext) else {
                let fallbackName = fileURL.deletingPathExtension().lastPathComponent
                fonts.append(FontItem(
                    fileID: fileID,
                    sourceURL: fileURL,
                    relativePath: relativePath,
                    displayName: fileURL.lastPathComponent,
                    postScriptName: fallbackName,
                    familyName: fallbackName,
                    styleName: nil,
                    version: nil,
                    fileHash: "",
                    category: category,
                    installStatus: .unsupported,
                    isFavorite: favorites.contains(fallbackName),
                    isCompared: compared.contains(fallbackName)
                ))
                continue
            }

            let hash: String
            do {
                hash = try FileHash.sha256Hex(for: fileURL)
            } catch {
                skipped.append(SkippedFontFile(path: relativePath, reason: "无法读取文件 hash：\(error.localizedDescription)"))
                continue
            }

            registerForProcessPreview(fileURL)
            let metadataItems = FontMetadataReader.metadata(for: fileURL)
            guard !metadataItems.isEmpty else {
                skipped.append(SkippedFontFile(path: relativePath, reason: "CoreText 无法解析字体元数据"))
                continue
            }

            for metadata in metadataItems {
                let status = installStatus(
                    postScriptName: metadata.postScriptName,
                    fileHash: hash,
                    installedSnapshot: installedSnapshot
                )

                fonts.append(FontItem(
                    fileID: fileID,
                    sourceURL: fileURL,
                    relativePath: relativePath,
                    displayName: metadata.displayName,
                    postScriptName: metadata.postScriptName,
                    familyName: metadata.familyName,
                    styleName: metadata.styleName,
                    version: metadata.version,
                    fileHash: hash,
                    category: category,
                    installStatus: status,
                    isFavorite: favorites.contains(metadata.postScriptName),
                    isCompared: compared.contains(metadata.postScriptName)
                ))
            }
        }

        return FontScanResult(
            fonts: fonts.sorted { lhs, rhs in
                lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            },
            skipped: skipped
        )
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
            guard FontItem.fontLikeExtensions.contains(url.pathExtension.lowercased()) else { continue }
            urls.append(url)
        }
        return urls
    }

    private func registerForProcessPreview(_ url: URL) {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }

    private func installStatus(
        postScriptName: String,
        fileHash: String,
        installedSnapshot: InstalledFontSnapshot
    ) -> FontInstallStatus {
        guard installedSnapshot.postScriptNames.contains(postScriptName) else {
            return .missing
        }

        if let installedHashes = installedSnapshot.fileHashesByPostScriptName[postScriptName],
           !installedHashes.isEmpty,
           !installedHashes.contains(fileHash) {
            return .conflict
        }

        return .installed
    }
}
