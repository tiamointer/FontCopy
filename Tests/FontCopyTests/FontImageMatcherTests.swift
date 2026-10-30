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

/// 海报里两行字用了不同字体：选中其中一行切下来，只在那块里认字比对。
@Test func findsTheFontOfOneSelectedLine() async throws {
    let candidates = ["STSongti-SC-Regular", "STKaiti-SC-Regular", "PingFangSC-Semibold", "HiraginoSans-W3"]
        .compactMap(systemFontItem)
    try #require(candidates.count == 4)
    let top = try #require(FontImageMatcher.renderLine("永和九年在山", font: candidates[0], height: 120))
    let bottom = try #require(FontImageMatcher.renderLine("天朗气清惠风", font: candidates[1], height: 120))

    let width = max(top.width, bottom.width) + 80
    let height = 400
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(top, in: CGRect(x: 40, y: 240, width: top.width, height: top.height))
    context.draw(bottom, in: CGRect(x: 40, y: 40, width: bottom.width, height: bottom.height))
    let poster = try #require(context.makeImage())

    let lines = try FontImageMatcher.recognizeLines(poster)
    #expect(lines.count == 2)
    let lower = try #require(lines.min { $0.box.minY < $1.box.minY })
    let box = lower.box.insetBy(dx: -lower.box.height * 0.3, dy: -lower.box.height * 0.3)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixelRect = CGRect(
        x: box.minX * Double(width), y: (1 - box.maxY) * Double(height),
        width: box.width * Double(width), height: box.height * Double(height)
    ).integral
    let piece = try #require(poster.cropping(to: pixelRect))

    let recognized = try FontImageMatcher.recognize(piece)
    let targets = FontImageMatcher.targets(from: piece, characters: recognized)
    let ranked = FontImageMatcher.rank(targets: targets, fonts: candidates)
    #expect(ranked.first?.font.postScriptName == candidates[1].postScriptName)
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
