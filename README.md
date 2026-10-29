# Openly

A small native macOS utility for managing default apps by file type.

管理 macOS 文件类型的默认打开应用。SwiftUI + AppKit 原生实现，无第三方依赖，无联网功能。

## 功能

- 查看当前默认应用，按文件类别筛选。
- 搜索文件类型、扩展名或当前应用。
- 从兼容应用菜单中修改默认应用，或自行选择本机 `.app`。
- 添加扩展名，或拖入文件识别实际系统类型。
- 保存最近 50 条修改记录，支持撤销。
- 黑白灰界面，保留应用图标原色；支持系统深浅色外观。
- `⌘F` 搜索，`⌘R` 刷新。关闭窗口后退出。

## 下载

从 [Releases](https://github.com/DanieeHan/Openly/releases) 下载 `Openly.zip`，解压后打开 `Openly.app`，也可移入“应用程序”目录。

预编译版本适用于 Apple Silicon（M 系列芯片），需要 macOS 13 或更新版本。当前版本使用本地临时签名，尚未完成 Developer ID 签名、公证或 App Store 发布；macOS 可能阻止直接打开。也可以从源码自行构建。

## 从源码构建

需要 macOS 13+ 和 Apple Command Line Tools（或包含命令行工具的 Xcode）。

```sh
git clone https://github.com/DanieeHan/Openly.git
cd Openly
zsh build.sh
open dist/Openly.app
```

产物为 `dist/Openly.app` 和 `dist/Openly.zip`。默认按当前 Mac 的处理器架构编译；可以设置 `OPENLY_ARCH=arm64` 或 `OPENLY_ARCH=x86_64` 进行交叉编译。Intel 构建尚未在实机验证。

```sh
# 指定输出位置
zsh build.sh /path/to/Openly.app

# 运行逻辑测试，不改动本机默认应用
zsh test.sh
```

## 行为说明

修改会作用于系统内容类型，而非单个文件；属于同一类型的扩展名（例如 `.jpg` / `.jpeg`）会合并显示。应用菜单中显示系统类型标识。浏览器链接分流暂未包含。

需要用户同意时，由 macOS 自身显示确认提示。失败时显示错误，等待操作完成期间禁用修改。

撤销前会检查当前关联是否仍是该条记录设置的应用，避免覆盖后续修改。原始应用不存在或原本没有默认应用时无法撤销。记录只包含在 Openly 中完成的修改，不是所有系统设置的历史。

自定义类型与修改记录保存在本机用户偏好中。软件不联网、不收集遥测、不后台监控；预置列表不是系统所有文件类型的完整枚举。

## 源码结构

| 文件 | 内容 |
| --- | --- |
| `Sources/Model.swift` | 类型识别、系统接口、修改记录与撤销 |
| `Sources/Openly.swift` | 原生窗口、搜索、分类、应用菜单与历史记录 |
| `Tests/ModelTests.swift` | 使用替代服务验证修改与撤销，真实系统接口只读取 |
| `Resources/` | App 信息和图标 |
| `Tools/MakeIcon.swift` | App 图标生成源码 |

测试覆盖类型去重、搜索、分类、自定义类型、持久化、文件导入、修改成功与失败、撤销和后续设置保护。系统授权弹窗及不同 macOS 版本的写入行为需要实机验证。

## License

[MIT](LICENSE) · Copyright (c) 2026 Daniel Han.
