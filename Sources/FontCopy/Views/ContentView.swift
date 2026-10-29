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
                .disabled(!store.canRescan)

                Menu {
                    Button {
                        store.normalizeSingleFontFile()
                    } label: {
                        Label("选择字体文件...", systemImage: "doc")
                    }

                    Button {
                        store.normalizeFontFolder()
                    } label: {
                        Label("选择文件夹批量处理...", systemImage: "folder")
                    }
                } label: {
                    Label("规范化字体名称", systemImage: "pencil.and.outline")
                }
                .disabled(store.isScanning || store.isInstalling || store.isNormalizingFontNames)
                .help("只改写字体文件内部名称，不会安装字体")

                Button {
                    store.confirmAndInstallAllMissing()
                } label: {
                    Label("安装当前未安装", systemImage: "square.and.arrow.down")
                }
                .disabled(store.installableFonts.isEmpty || store.isInstalling || store.isNormalizingFontNames)
                .help("批量安装当前可见范围内的未安装字体到 /Library/Fonts，会先显示确认")

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
        .sheet(isPresented: $store.isImageMatchPresented) {
            ImageFontMatchView(store: store)
                .frame(minWidth: 1040, idealWidth: 1120, minHeight: 700, idealHeight: 760)
        }
        .task {
            await store.restoreLastFolderIfAvailable()
        }
        .alert("FontCopy", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
