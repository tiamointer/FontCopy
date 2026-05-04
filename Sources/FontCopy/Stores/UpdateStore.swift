import AppKit
import FontCopyCore
import Foundation
import SwiftUI

@MainActor
final class UpdateStore: ObservableObject {
    @Published var watchFolder: URL?
    @Published var availableUpdate: AppUpdate?
    @Published var lastError: String?
    @Published var isChecking = false
    @Published var isInstalling = false
    @Published var didCheckOnce = false

    private let service = UpdateService()
    private let folderKey = "FontCopy.UpdateWatchFolder"

    init() {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            watchFolder = URL(fileURLWithPath: path)
        }
    }

    var currentVersion: String { service.currentVersion() }

    func setWatchFolder(_ url: URL?) {
        watchFolder = url
        availableUpdate = nil
        lastError = nil
        didCheckOnce = false
        if let url {
            UserDefaults.standard.set(url.path, forKey: folderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: folderKey)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择监视文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            setWatchFolder(url)
            check()
        }
    }

    func check() {
        guard let folder = watchFolder, !isChecking else { return }
        isChecking = true
        lastError = nil
        let service = self.service
        Task.detached {
            let outcome: Result<AppUpdate?, Error>
            do {
                outcome = .success(try service.scanForUpdate(in: folder))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.isChecking = false
                self.didCheckOnce = true
                switch outcome {
                case .success(let update):
                    self.availableUpdate = update
                case .failure(let error):
                    self.availableUpdate = nil
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func installAvailable() {
        guard let update = availableUpdate, !isInstalling else { return }
        isInstalling = true
        lastError = nil
        Task.detached {
            do {
                try await UpdateInstaller.install(update: update)
                // App terminates inside the installer; this point is unreachable on success.
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
}
