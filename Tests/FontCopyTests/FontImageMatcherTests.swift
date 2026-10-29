import CoreGraphics
import CoreText
import FontCopyCore
import Foundation
import Testing

@Test func findsTheFontAnImageWasSetIn() async throws {
    let candidates = ["STSongti-SC-Regular", "STKaiti-SC-Regular", "PingFangSC-Semibold", "HiraginoSans-W3"]
        .compactMap(systemFontItem)
    try #require(candidates.count == 4)

    for expected in candidates {
        let image = try #require(FontImageMatcher.renderLine("永和九年在山", font: expected, height: 160))
        let recognized = try FontImageMatcher.recognize(image)
        #expect(recognized.count >= 4)

        let targets = FontImageMatcher.targets(from: image, characters: recognized)
        let ranked = FontImageMatcher.rank(targets: targets, fonts: candidates)
        #expect(ranked.first?.font.postScriptName == expected.postScriptName)
    }
}

private func systemFontItem(_ postScriptName: String) -> FontItem? {
    let descriptor = CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 12)
    guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL,
          FontMetadataReader.stringAttribute(descriptor, key: kCTFontNameAttribute) == postScriptName else {
        return nil
    }
    return FontItem(
        fileID: UUID(), sourceURL: url, relativePath: url.lastPathComponent,
        displayName: postScriptName, postScriptName: postScriptName, familyName: postScriptName,
        styleName: nil, version: nil, fileHash: "", category: "系统",
        installStatus: .installed, isFavorite: false, isCompared: false
    )
}
