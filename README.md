# Deleter

macOS 照片/视频筛选器。浏览目录、快速预览、标记丢弃，并为标记项生成压缩副本，确认无误后丢弃原片。

## 功能

- **Finder 风格网格**：文件夹与媒体混合展示，等间距方形缩略图，懒加载按需生成。
- **快速预览**：空格全屏 Quick Look，方向键切换，支持缩放与视频播放。
- **键盘驱动**：方向键导航，`D` 标记/撤销丢弃，回车进入文件夹或预览，退格返回上层。
- **RAW + JPG 配对**：自动识别同 base 名的 RAW/JPG，可合并或分开显示。
- **压缩副本（B-side）**：标记项在原片同目录的 `_bside` 子文件夹生成压缩副本——图片转 JPEG（可调质量），视频重新编码（可调码率）。
- **丢弃原片**：副本生成完成后，一键将原片移入废纸篓。
- **实时容量**：顶栏显示 当前目录 / 根目录 / 磁盘可用 三档容量。

## 实现思路

- **纯 Swift + SwiftUI / AppKit**，命令行工具链（`swiftc`）即可编译，不依赖 Xcode 工程文件。
- **状态集中**：`AppModel`（`ObservableObject`）持有目录树、配对、标记、压缩任务等全部状态，视图无状态化。
- **目录扫描与配对**：`DirectoryScanner` 遍历文件，`PairingService` 按 base 名 + 扩展名归并 RAW/JPG 为 `MediaPair`。
- **缩略图缓存**：`ThumbnailCache` 按 URL + 尺寸做内存缓存，RAW 经 `RawDecoder`（CGImageSource）解码，避免重复解码。
- **压缩调度**：`BsideScheduler` 串行调度 `BsideJob`；`ImageCompressor` / `VideoCompressor` 分别用 CGImageDestination 与 AVAssetReader→AVAssetWriter 管线转码，输出到 `BsidePathResolver` 解析的 `_bside` 路径。
- **键事件**：`NSEvent` 本地监听器捕获按键，屏蔽系统重复以避免误触发；文本输入焦点时自动放行。
- **主题**：`Theme.swift` 统一定义深红主题色，顶栏容量显示用灰度。

## 构建

```bash
./build.sh        # 产出 Build/Deleter.app
./make_icon.py    # 生成图标（需 Pillow、numpy）
./package_dmg.sh  # 打包为 release/v1.0/Deleter.dmg
```

要求 macOS 14+、Swift 命令行工具。

## 许可

Apache License 2.0，详见 [LICENSE](LICENSE)。
