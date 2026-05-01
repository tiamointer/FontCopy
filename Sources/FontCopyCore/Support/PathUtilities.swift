import Foundation

public enum PathUtilities {
    public static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }

        let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        var relative = String(filePath[start...])
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.isEmpty ? fileURL.lastPathComponent : relative
    }

    public static func category(for relativePath: String) -> String {
        let url = URL(fileURLWithPath: relativePath)
        let parent = url.deletingLastPathComponent().path
        return parent == "." || parent == "/" || parent.isEmpty ? "未分类" : parent
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
