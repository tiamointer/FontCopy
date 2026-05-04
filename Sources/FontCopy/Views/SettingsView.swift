import SwiftUI

struct SettingsView: View {
    @StateObject private var updates = UpdateStore()

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            updateTab
                .tabItem { Label("更新", systemImage: "arrow.down.circle") }
        }
        .frame(width: 500, height: 360)
    }

    private var generalTab: some View {
        Form {
            LabeledContent("安装位置", value: "/Library/Fonts")
            Text("系统全局字体安装需要管理员授权。首版不会覆盖已有字体文件。")
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var updateTab: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: updates.currentVersion)
                HStack(spacing: 8) {
                    Text("监视文件夹")
                    Spacer()
                    Text(updates.watchFolder?.path ?? "未设置")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择…") { updates.chooseFolder() }
                }
            } footer: {
                Text("从此文件夹中查找 FontCopy 安装包（FontCopy-1.2.0.dmg 或 FontCopy.app）。版本高于当前即提示升级。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        updates.check()
                    } label: {
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("立即检查")
                        }
                    }
                    .disabled(updates.watchFolder == nil || updates.isChecking)

                    Spacer()

                    if let upd = updates.availableUpdate {
                        Button {
                            updates.installAvailable()
                        } label: {
                            if updates.isInstalling {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("安装 \(upd.version) 并重启")
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(updates.isInstalling)
                    }
                }

                if let upd = updates.availableUpdate {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("发现新版本 \(upd.version)", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)

                        if let notes = upd.notes {
                            ScrollView {
                                Text(notes)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .frame(minHeight: 80, maxHeight: 160)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.25))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text("（此版本未附带更新说明）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if updates.didCheckOnce, updates.lastError == nil {
                    Label("已是最新版本", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                if let err = updates.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task {
            if updates.watchFolder != nil { updates.check() }
        }
    }
}
