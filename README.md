# LacEditor

一款安静、快速、真正属于 macOS 的文本与代码编辑器。

LacEditor 为日常文本、Markdown、JSON 和代码编辑而生：打开即写，标签切换顺手，预览只在需要时出现，
复杂功能藏在原生菜单和快捷键里。它不要求登录，不连接云端，也不会收集你的文档内容。

<p>
  <a href="https://github.com/kolmh/LacEditor/releases/latest">下载最新版</a>
  ·
  <a href="https://github.com/kolmh/LacEditor/releases/tag/v0.13.7">查看更新日志</a>
  ·
  <a href="https://github.com/kolmh/LacEditor/issues">反馈问题</a>
</p>

> 当前版本：`0.13.18` · macOS 26+ · Apple Silicon

## 为什么是 LacEditor？

- **打开就能写**：没有账号、工作区向导和多余的项目配置，启动后直接进入编辑区。
- **专注但不简陋**：多标签、查找替换、语法高亮、Markdown 预览和 JSON 工具都在手边，界面仍保持克制。
- **像 macOS 应用一样自然**：原生窗口、菜单、文件选择器、快捷键、深色模式和拖拽行为全部遵循系统习惯。
- **大文件也能继续工作**：针对长代码和日志文件采用可视区布局、后台任务和分级保护策略，优先保证输入与滚动流畅。
- **你的内容留在你的 Mac 上**：本地文件、本地预览、本地恢复；不登录、不联网、不上传文档。

## 核心体验

### 编辑文本与代码

支持 TXT、Markdown、JSON、HTML、JavaScript、TypeScript、CSS、Python、Swift、Shell、YAML、C/C++、SQL
等常见格式。提供行号、当前行高亮、自动缩进、Tab 缩进、撤销重做、基础折叠和括号配对高亮。

### Markdown 双栏预览

编辑与预览左右并排，实时渲染标题、段落、列表、引用、分割线、链接、行内代码、代码块、表格和 GFM
扩展。预览可随时关闭，长文档不会被迫进入笔记式工作流。

### JSON 工具不打乱内容

格式化和压缩只调整结构空白，保留对象字段顺序、重复键、数值字面量和字符串转义写法；无效 JSON 会
尽量报告行号与列号。所有修改都可以用一次撤销恢复。

### 文件与窗口管理

支持多窗口、多标签、标签拖动排序、标签拖出成窗口、最近文件、收藏夹和自定义分组。同一个磁盘文件
在多个窗口中只会打开一个可编辑实例，外部文件发生变化时默认不会静默覆盖。

### 退出后继续工作

默认退出时保留完整工作区，下次启动恢复窗口、标签、正文、未保存状态、选区、滚动位置和界面状态。
工作区快照与异常退出恢复分开保存，磁盘文件不会被自动改写；也可以在设置中切换为传统的退出前保存确认。

## 下载使用

在 [Releases](https://github.com/kolmh/LacEditor/releases) 下载最新的 arm64 ZIP，解压后将 `LacEditor.app`
拖入“应用程序”即可。

首次打开本机 ad-hoc 签名版本时，如果 macOS 阻止启动，请前往“系统设置 > 隐私与安全性”允许打开。

## 从源码构建

环境要求：

- macOS 26+
- Apple Silicon Mac
- Xcode 26+

```bash
git clone https://github.com/kolmh/LacEditor.git
cd LacEditor
swift build
swift test
```

需要运行完整发布验收时：

```bash
./Scripts/run-acceptance.sh
```

也可以用 Xcode 打开 `LacEditor.xcodeproj`，选择 `LacEditor` scheme 后按 `Command+R`。

## 技术方向

LacEditor 使用 SwiftUI 构建界面，AppKit `NSTextView` 负责编辑，TextKit 负责可视区布局，WebKit 配合
`cmark-gfm` 负责本地 Markdown 预览。文件读写、语法扫描、搜索替换、JSON、预览和恢复各自保持独立，
后台任务通过文档 revision 校验，过期结果不会覆盖较新的编辑内容。

## 路线图

完整的性能与架构路线记录在 [docs/ROADMAP.md](docs/ROADMAP.md)，当前规划分为三阶段：

- 第一阶段：减少 Markdown 预览全文复制、完善搜索缓存、补齐行号和末尾空行回归测试。
- 第二阶段：按脏范围剪枝 Tree-sitter，拆分高亮/折叠任务，减少长代码文件的主线程工作。
- 第三阶段：抽象 TextKit 渲染属性，验证 TextKit 2 和更原生的文档生命周期方案。

Git、插件系统、云同步和双向链接暂不属于 LacEditor 的核心路线。

## 参与贡献

欢迎通过 [Issues](https://github.com/kolmh/LacEditor/issues) 报告问题或提出建议。提交功能修改前，
请先说明用户场景，并运行 `swift test` 与 `./Scripts/run-acceptance.sh`。

项目的版本、提交和发布规则见 [VERSIONING.md](VERSIONING.md)，完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。
