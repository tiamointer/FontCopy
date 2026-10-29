import Foundation
import Testing
@testable import FontCopyCore

@Test func splitsWeightSuffixFromFileStem() {
    #expect(FontFamilyGrouping.split(stem: "未来荧黑简体-常规")! == ("未来荧黑简体", "常规"))
    #expect(FontFamilyGrouping.split(stem: "vivoSans-ExtraBold")! == ("vivoSans", "ExtraBold"))
    #expect(FontFamilyGrouping.split(stem: "站酷仓耳渔阳体-W03")! == ("站酷仓耳渔阳体", "W03"))
    #expect(FontFamilyGrouping.split(stem: "江城正义体 400W")! == ("江城正义体", "400W"))
    #expect(FontFamilyGrouping.split(stem: "香萃打字机体 W35")! == ("香萃打字机体", "W35"))
    #expect(FontFamilyGrouping.split(stem: "Empo Sans 2") == nil)
    #expect(FontFamilyGrouping.split(stem: "长坂点宋16-SC") == nil)
    #expect(FontFamilyGrouping.split(stem: "霞鹜晰黑(重制版)-CL")! == ("霞鹜晰黑(重制版)", "CL"))
    #expect(FontFamilyGrouping.split(stem: "仓耳非白W03")! == ("仓耳非白", "W03"))
    #expect(FontFamilyGrouping.split(stem: "白无常可可体粗")! == ("白无常可可体", "粗"))
    #expect(FontFamilyGrouping.split(stem: "有爱黑体normal ")! == ("有爱黑体", "normal"))
    #expect(FontFamilyGrouping.split(stem: "舟方日明体斜体")! == ("舟方日明体", "斜体"))
    #expect(FontFamilyGrouping.split(stem: "游趣体") == nil)
}

@Test func foldsWeightsOfOneFamilyAndOrdersLightToHeavy() {
    let fonts = [
        font("黑体Gothic/荣耀字体-粗体.ttf"),
        font("黑体Gothic/游趣体.ttf"),
        font("黑体Gothic/荣耀字体-常规.ttf"),
        font("黑体Gothic/荣耀字体-极细.ttf"),
        font("黑体Gothic/孤单体-常规.ttf"),
        font("宋体Ming/荣耀字体-常规.ttf")
    ]

    let groups = FontFamilyGrouping.group(fonts)

    #expect(groups.map(\.name) == ["荣耀字体", "游趣体", "孤单体-常规", "荣耀字体-常规"])
    #expect(groups[0].weightNames == ["极细", "常规", "粗体"])
    #expect(groups[0].members[groups[0].representativeIndex].relativePath == "黑体Gothic/荣耀字体-常规.ttf")
    #expect(!groups[2].isFamily)
}

@Test func singleLetterWeightsNeedSiblings() {
    let groups = FontFamilyGrouping.group([
        font("宋体Ming/猫啃网文明宋-L.ttf"),
        font("宋体Ming/猫啃网文明宋-B.ttf"),
        font("宋体Ming/猫啃网文明宋-R.ttf"),
        font("黑体Gothic/源古黑體-F.ttf")
    ])

    #expect(groups.count == 2)
    #expect(groups[0].weightNames == ["L", "R", "B"])
    #expect(groups[0].members[groups[0].representativeIndex].relativePath.hasSuffix("-R.ttf"))
}

@Test func foldsNumericWeightsButKeepsItalicFamiliesApart() {
    let groups = FontFamilyGrouping.group([
        font("黑体Gothic/江城黑体 600W.ttf"),
        font("黑体Gothic/江城黑体 200W.ttf"),
        font("黑体Gothic/江城黑体 400W.ttf"),
        font("黑体Gothic/江城黑体 Italic 400W.ttf"),
        font("黑体Gothic/江城黑体 Italic 600W.ttf")
    ])

    #expect(groups.map(\.name) == ["江城黑体", "江城黑体 Italic"])
    #expect(groups[0].weightNames == ["200W", "400W", "600W"])
    #expect(groups[0].weightNames[groups[0].representativeIndex] == "400W")
}

@Test func foldsStyleVariantsAndBareNamedFiles() {
    let groups = FontFamilyGrouping.group([
        font("像素Pixel/点点像素体-圆形.ttf"),
        font("像素Pixel/点点像素体-方形.ttf"),
        font("黑体Gothic/未来荧黑.otf", style: "Compressed Book"),
        font("黑体Gothic/未来荧黑-粗.otf"),
        font("黑体Gothic/未来荧黑-常规.otf"),
        font("宋体Ming/舟方日明体.otf", style: "Regular"),
        font("宋体Ming/舟方日明体斜体.otf"),
        font("宋体Ming/长坂点宋16-SC.ttf"),
        font("宋体Ming/长坂点宋16-TC.ttf")
    ])

    #expect(groups.map(\.name) == ["点点像素体", "未来荧黑", "舟方日明体", "长坂点宋16-SC", "长坂点宋16-TC"])
    #expect(groups[0].weightNames == ["圆形", "方形"])
    #expect(groups[1].weightNames == ["常规", "粗", "Compressed Book"])
    #expect(groups[1].weightNames[groups[1].representativeIndex] == "常规")
    #expect(groups[2].weightNames == ["Regular", "斜体"])
}

@Test func repeatedLabelsStayDistinguishable() {
    let groups = FontFamilyGrouping.group([
        font("黑体Gothic/檎风黑体-常规.ttc"),
        font("黑体Gothic/檎风黑体-常规.ttc"),
        font("黑体Gothic/檎风黑体-常规.ttf"),
        font("黑体Gothic/檎风黑体-粗.ttf")
    ])

    #expect(groups.count == 1)
    #expect(groups[0].weightNames == ["常规 · ttc 1", "常规 · ttc 2", "常规 · ttf", "粗"])
}

private func font(_ relativePath: String, style: String? = nil) -> FontItem {
    let stem = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    return FontItem(
        fileID: UUID(), sourceURL: URL(fileURLWithPath: "/library/" + relativePath),
        relativePath: relativePath, displayName: stem, postScriptName: stem,
        familyName: stem, styleName: style, version: nil, fileHash: "",
        category: (relativePath as NSString).deletingLastPathComponent,
        installStatus: .missing, isFavorite: false, isCompared: false
    )
}
