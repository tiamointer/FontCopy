import Foundation
import Testing
@testable import FontCopyCore

@Test func comparesFontRevisionsAsDecimals() {
    #expect(FontUpdatePlanner.compareVersions("Version 1.522", "Version 1.5") == .orderedDescending)
    #expect(FontUpdatePlanner.compareVersions("Version 1.500;hotconv", "1.5") == .orderedSame)
    #expect(FontUpdatePlanner.compareVersions("Version 1.10.2", "Version 1.9.0") == .orderedDescending)
    #expect(FontUpdatePlanner.compareVersions("Version 2.001", "Version 10.0") == .orderedAscending)
    #expect(FontUpdatePlanner.compareVersions("Version", "1.0") == nil)
}

@Test func directionFollowsVersions() {
    #expect(FontUpdatePlanner.direction(library: "1.522", installed: "1.501") == .libraryNewer)
    #expect(FontUpdatePlanner.direction(library: "1.501", installed: "1.522") == .installedNewer)
    #expect(FontUpdatePlanner.direction(library: "1.5", installed: "1.500") == .sameVersion)
    #expect(FontUpdatePlanner.direction(library: nil, installed: "1.0") == .unknown)
}

@Test func planUpdatesLibraryNewerAndSkipsUnsafeCases() {
    let fonts = ["Newer", "Older", "Shared", "Protected"].map(conflictFont)
    let installed = URL(fileURLWithPath: "/Library/Fonts")
    let snapshot = InstalledFontSnapshot(
        postScriptNames: ["Newer", "Older", "Shared", "Other", "Protected"],
        fileHashesByPostScriptName: [:],
        urlsByPostScriptName: [
            "Newer": [installed.appendingPathComponent("Newer.ttf")],
            "Older": [installed.appendingPathComponent("Older.ttf")],
            "Shared": [installed.appendingPathComponent("Pack.ttc")],
            "Other": [installed.appendingPathComponent("Pack.ttc")],
            "Protected": [URL(fileURLWithPath: "/System/Library/Fonts/Protected.ttf")]
        ],
        userRemovableRoots: [installed]
    )
    let versions = [
        "/library/Newer.ttf": "1.522", "/Library/Fonts/Newer.ttf": "1.501",
        "/library/Older.ttf": "1.0", "/Library/Fonts/Older.ttf": "2.0"
    ]

    let plan = FontUpdatePlanner.plan(for: fonts, snapshot: snapshot) { url, _ in versions[url.path] }
    let byName = Dictionary(uniqueKeysWithValues: plan.map { ($0.font.postScriptName, $0) })

    #expect(byName["Newer"]?.isUpdatable == true)
    #expect(byName["Newer"]?.installedURLs.map(\.lastPathComponent) == ["Newer.ttf"])
    #expect(byName["Older"]?.direction == .installedNewer)
    #expect(byName["Older"]?.isUpdatable == false)
    #expect(byName["Shared"]?.blockedReason?.contains("合集") == true)
    #expect(byName["Protected"]?.isUpdatable == false)
}

@Test func planReplacesVariableInstancesTogetherAndRefusesBrokenLibraryFiles() {
    let fonts = ["Variable", "Broken"].map(conflictFont)
    let installed = URL(fileURLWithPath: "/Library/Fonts")
    let snapshot = InstalledFontSnapshot(
        postScriptNames: ["Variable", "Variable-Bold", "Broken"],
        fileHashesByPostScriptName: [:],
        urlsByPostScriptName: [
            "Variable": [installed.appendingPathComponent("Variable.ttf")],
            "Variable-Bold": [installed.appendingPathComponent("Variable.ttf")],
            "Broken": [installed.appendingPathComponent("Broken.ttf")]
        ],
        userRemovableRoots: [installed]
    )

    let plan = FontUpdatePlanner.plan(
        for: fonts,
        snapshot: snapshot,
        readVersion: { _, _ in nil },
        libraryProblem: { $0.lastPathComponent == "Broken.ttf" ? "nameID 256" : nil },
        faceNames: { $0.lastPathComponent == "Variable.ttf" ? ["Variable", "Variable-Bold"] : [] }
    )

    #expect(plan[0].isUpdatable)
    #expect(plan[1].blockedReason?.contains("名称表有缺陷") == true)
    #expect(FontUpdatePlanner.shortVersion("Version 1.530; October 18, 2026") == "1.530")
}

private func conflictFont(_ postScriptName: String) -> FontItem {
    FontItem(
        fileID: UUID(), sourceURL: URL(fileURLWithPath: "/library/\(postScriptName).ttf"),
        relativePath: "\(postScriptName).ttf", displayName: postScriptName,
        postScriptName: postScriptName, familyName: postScriptName, styleName: nil,
        version: nil, fileHash: "", category: "测试",
        installStatus: .conflict, isFavorite: false, isCompared: false
    )
}
