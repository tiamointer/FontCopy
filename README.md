# FontCopy

FontCopy 是一款原生 macOS 字体预览与富文本复制工具，使用 SwiftUI + AppKit/CoreText 构建。

## 功能

- 导入字体文件夹并扫描 `.ttf`、`.otf`、`.ttc`、`.otc`、`.woff`、`.woff2`
- 使用 CoreText 读取 PostScript name、family、style 等字体元数据
- 检测导入字体是否已在本机安装
- 单个安装或批量安装缺失字体到 `/Library/Fonts`
- 收藏、搜索、分类、比较字体
- AppKit `NSCollectionView` 虚拟化预览网格
- 复制 FCPX 可用的 RTF 富文本样式
- 解析剪贴板中的 RTF/HTML 字体信息

## 运行

```bash
swift build
swift test
./script/build_and_run.sh
```

系统级安装字体需要管理员授权。首版不会覆盖 `/Library/Fonts` 中已有同名文件。
