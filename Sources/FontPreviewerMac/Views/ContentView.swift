import SwiftUI

struct ContentView: View {
    @StateObject private var store = FontLibraryStore()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            PreviewPaneView(store: store)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.chooseFolder()
                } label: {
                    Label("导入文件夹", systemImage: "folder.badge.plus")
                }

                Button {
                    store.rescan()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .disabled(store.fonts.isEmpty || store.isScanning)

                Button {
                    store.installAllMissing()
                } label: {
                    Label("安装全部未安装", systemImage: "square.and.arrow.down")
                }
                .disabled(store.installableFonts.isEmpty || store.isInstalling)

                Button {
                    store.presentClipboardInspector()
                } label: {
                    Label("分析剪贴板", systemImage: "doc.on.clipboard")
                }
            }
        }
        .sheet(isPresented: $store.isClipboardInspectorPresented) {
            ClipboardInspectorView(store: store)
                .frame(width: 760, height: 620)
        }
        .alert("字体预览器", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
