import AppKit
import Foundation

public struct PasteboardService: Sendable {
    public init() {}

    public func copyRichTextForFCPX(text: String, font: FontItem, fontSize: Double) {
        let rtf = """
        {\\rtf1\\ansi\\ansicpg1252\\deff0\\nouicompat\\deflang1033\\deflangfe2052
        {\\fonttbl{\\f0\\fswiss\\fcharset0 \(rtfEscaped(font.postScriptName));}}
        {\\colortbl;\\red255\\green255\\blue255;}
        \\pard\\partightenfactor0
        \\f0\\fs\(Int(fontSize * 2)) \\cf1 \\qc
        \(rtfEscaped(text))
        }
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(rtf.utf8), forType: .rtf)
    }

    public func analyzeClipboard() -> ClipboardAnalysis {
        let pasteboard = NSPasteboard.general
        let rtf = pasteboard.string(forType: .rtf)
        let html = pasteboard.string(forType: .html)
        let plainText = pasteboard.string(forType: .string)

        var ordered: [String: ClipboardFontMatch] = [:]
        for name in parseFontsFromHTML(html ?? "") {
            ordered[name.lowercased()] = ClipboardFontMatch(name: name, source: .html)
        }
        for name in parseFontsFromRTF(rtf ?? "") {
            ordered[name.lowercased()] = ClipboardFontMatch(name: name, source: .rtf)
        }

        return ClipboardAnalysis(
            rtf: rtf,
            html: html,
            plainText: plainText,
            fonts: Array(ordered.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    public func parseFontsFromHTML(_ html: String) -> [String] {
        guard !html.isEmpty else { return [] }
        var fontNames = Set<String>()
        let styleContent = firstCapture(in: html, pattern: #"<style[^>]*>([\s\S]*?)</style>"#, options: [.caseInsensitive]) ?? ""
        let target = styleContent + html

        for families in captures(in: target, pattern: #"font:\s*(?:[^;]*?\s)?\d*\.?\d+(?:px|pt|em|rem|%)\s+([^;]+);"#, options: [.caseInsensitive]) {
            processFontFamilies(families, into: &fontNames)
        }
        for families in captures(in: target, pattern: #"font-family:\s*([^;]+);"#, options: [.caseInsensitive]) {
            processFontFamilies(families, into: &fontNames)
        }

        return Array(fontNames).sorted()
    }

    public func parseFontsFromRTF(_ rtf: String) -> [String] {
        guard !rtf.isEmpty else { return [] }
        var fontNames = Set<String>()
        for name in captures(in: rtf, pattern: #"\{\\f\d+[^{};]*\s+([^;{}]+);\}"#) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            if !clean.isEmpty && !clean.hasPrefix("\\") {
                fontNames.insert(clean)
            }
        }
        return Array(fontNames).sorted()
    }

    private func processFontFamilies(_ value: String, into fontNames: inout Set<String>) {
        value.split(separator: ",").forEach { raw in
            let name = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty {
                fontNames.insert(name)
            }
        }
    }

    private func captures(in text: String, pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func firstCapture(in text: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
        captures(in: text, pattern: pattern, options: options).first
    }

    private func rtfEscaped(_ text: String) -> String {
        var output = ""
        for unit in text.utf16 {
            switch unit {
            case 92:
                output += "\\\\"
            case 123:
                output += "\\{"
            case 125:
                output += "\\}"
            case 10:
                output += "\\par\n"
            case 13:
                continue
            case 0...127:
                output.append(Character(UnicodeScalar(unit)!))
            default:
                output += "\\u\(Int(Int16(bitPattern: unit)))?"
            }
        }
        return output
    }
}
