import FontCopyCore
import Foundation
import Testing

@Test func detectsFontsThatCanNormalizeInternalName() async throws {
    let font = makeFontItem(fileName: "黄令东齐伋体.ttf", displayName: "QIJIC", familyName: "QIJIC")

    #expect(font.hasMismatchedInternalName)
    #expect(font.canNormalizeInternalName)
}

@Test func matchingVisibleNameDoesNotNeedNormalization() async throws {
    let font = makeFontItem(fileName: "黄令东齐伋体.ttf", displayName: "黄令东齐伋体", familyName: "QIJIC")

    #expect(!font.hasMismatchedInternalName)
    #expect(!font.canNormalizeInternalName)
}

@Test func fontCollectionsAreOfferedForNameNormalization() async throws {
    let font = makeFontItem(fileName: "集合字体.ttc", displayName: "Collection Internal", familyName: "Collection Internal")

    #expect(font.hasMismatchedInternalName)
    #expect(font.canNormalizeInternalName)
}

private func makeFontItem(fileName: String, displayName: String, familyName: String) -> FontItem {
    let url = URL(fileURLWithPath: "/tmp/\(fileName)")
    return FontItem(
        fileID: UUID(),
        sourceURL: url,
        relativePath: fileName,
        displayName: displayName,
        postScriptName: displayName,
        familyName: familyName,
        styleName: nil,
        version: nil,
        fileHash: "",
        category: "未分类",
        installStatus: .missing,
        isFavorite: false,
        isCompared: false
    )
}
