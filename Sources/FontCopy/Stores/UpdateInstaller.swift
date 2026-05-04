import AppKit
import FontCopyCore
import Foundation

enum UpdateInstaller {
    static func install(update: AppUpdate) async throws {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL

        let staging = fm.temporaryDirectory.appendingPathComponent(
            "fontcopy-update-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let stagedApp = staging.appendingPathComponent("FontCopy.app")

        switch update.source {
        case .app(let url):
            do {
                try fm.copyItem(at: url, to: stagedApp)
            } catch {
                throw UpdateError.copyFailed(error.localizedDescription)
            }

        case .dmg(let url):
            let mount = try mountDmg(url)
            defer { detachDmg(mount) }
            let entries = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
            guard let appURL = entries.first(where: { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("FontCopy") })
            else {
                throw UpdateError.noAppInDmg
            }
            do {
                try fm.copyItem(at: appURL, to: stagedApp)
            } catch {
                throw UpdateError.copyFailed(error.localizedDescription)
            }
        }

        let scriptURL = fm.temporaryDirectory.appendingPathComponent("fontcopy-update-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        SRC=\(shellEscape(stagedApp.path))
        DEST=\(shellEscape(bundleURL.path))
        STAGING=\(shellEscape(staging.path))
        PARENT=\(ProcessInfo.processInfo.processIdentifier)
        for i in $(seq 1 200); do
          if ! kill -0 "$PARENT" 2>/dev/null; then break; fi
          sleep 0.1
        done
        sleep 0.3
        rm -rf "$DEST"
        /bin/cp -R "$SRC" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        rm -rf "$STAGING"
        /usr/bin/open "$DEST"
        rm -- "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = nil
        process.standardError = nil
        process.standardInput = nil
        do {
            try process.run()
        } catch {
            throw UpdateError.scriptFailed(error.localizedDescription)
        }

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private static func mountDmg(_ url: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", url.path, "-nobrowse", "-noverify", "-noautoopen", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw UpdateError.mountFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailed("hdiutil exit \(process.terminationStatus)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw UpdateError.mountFailed("无法解析 hdiutil 输出")
        }
        for entity in entities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                return URL(fileURLWithPath: mp)
            }
        }
        throw UpdateError.mountFailed("未挂载到任何路径")
    }

    private static func detachDmg(_ mount: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.path, "-quiet"]
        process.standardOutput = nil
        process.standardError = nil
        try? process.run()
        process.waitUntilExit()
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
