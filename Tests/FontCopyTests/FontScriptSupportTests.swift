import CoreText
import FontCopyCore
import Foundation
import Testing

@Test func pingFangSCSupportsBothScripts() async throws {
    let descriptor = CTFontDescriptorCreateWithNameAndSize("PingFangSC-Regular" as CFString, 12)
    #expect(FontScriptSupport.measure(descriptor) == [.simplified, .traditional])
}

@Test func latinFontSupportsNeitherScript() async throws {
    let descriptor = CTFontDescriptorCreateWithNameAndSize("Helvetica" as CFString, 12)
    #expect(FontScriptSupport.measure(descriptor) == [])
}

@Test func fileNameSortsDualScriptFonts() async throws {
    let both: FontScriptSupport = [.simplified, .traditional]
    #expect(FontScriptSupport.resolve(measured: both, names: ["思源黑体繁体-常规"]) == .traditional)
    #expect(FontScriptSupport.resolve(measured: both, names: ["鸿雷板书简体-正式版"]) == .simplified)
    #expect(FontScriptSupport.resolve(measured: both, names: ["霞鹜文楷"]) == both)
    // 名字只能在实测支持的范围里归类，不能凭名字加上字体没有的文字
    #expect(FontScriptSupport.resolve(measured: .simplified, names: ["某某繁体"]) == .simplified)
}

@Test func filterHidesOnlyFontsMissingThatScript() async throws {
    #expect(!FontScriptSupport.traditional.isVisible(in: .simplified))
    #expect(!FontScriptSupport.simplified.isVisible(in: .traditional))
    #expect(FontScriptSupport([.simplified, .traditional]).isVisible(in: .simplified))
    #expect(FontScriptSupport([]).isVisible(in: .traditional))
    #expect(FontScriptSupport.traditional.isVisible(in: .all))
}
