import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            LabeledContent("安装位置", value: "/Library/Fonts")
            Text("系统全局字体安装需要管理员授权。首版不会覆盖已有字体文件。")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
