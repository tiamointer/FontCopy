import FontPreviewerCore
import Testing

@Test func parsesFontFamiliesFromHTML() async throws {
    let service = PasteboardService()
    let html = """
    <style>.title { font-family: 'PingFang SC', Helvetica, sans-serif; }</style>
    <span style="font: normal 42px 'Avenir Next', Arial;">Hello</span>
    """

    let fonts = service.parseFontsFromHTML(html)

    #expect(fonts.contains("PingFang SC"))
    #expect(fonts.contains("Avenir Next"))
    #expect(fonts.contains("Arial"))
}

@Test func parsesFontFamiliesFromRTF() async throws {
    let service = PasteboardService()
    let rtf = #"{\rtf1{\fonttbl{\f0\fswiss\fcharset0 HelveticaNeue;}{\f1\fnil PingFangSC-Regular;}}\f0 Hello}"#

    let fonts = service.parseFontsFromRTF(rtf)

    #expect(fonts.contains("HelveticaNeue"))
    #expect(fonts.contains("PingFangSC-Regular"))
}

@Test func shellQuotingEscapesSingleQuotes() async throws {
    let quoted = PathUtilities.shellQuoted("/tmp/A Font's File.otf")
    #expect(quoted == "'/tmp/A Font'\\''s File.otf'")
}
