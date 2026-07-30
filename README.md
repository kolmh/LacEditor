# LacEditor

LacEditor 是一款面向 macOS 14 及以上版本的轻量原生文本编辑器。工程使用 SwiftUI 构建界面，以 AppKit `NSTextView` 提供编辑能力，并使用 WebKit 在本地呈现 Markdown 预览。应用不需要登录、云同步或网络权限，也不采集用户内容。

当前版本：`0.1.0 (1)`

## 构建

1. 使用 Xcode 16 或兼容 macOS 14 SDK 的较新 Xcode 打开 `LacEditor.xcodeproj`。
2. 选择 `LacEditor` scheme 和 `My Mac`。
3. 按 `Command+R` 构建并运行。

工程还包含 `Package.swift`，可通过命令行检查源码：

```bash
swift build
swift build -c release
```

核心 JSON、Markdown 和折叠逻辑可独立验证：

```bash
swiftc \
  LacEditor/Models/EditorLanguage.swift \
  LacEditor/Models/EditorDocument.swift \
  LacEditor/Services/JSONFormatter.swift \
  LacEditor/Services/TextSearchService.swift \
  LacEditor/Editor/FoldService.swift \
  LacEditor/Editor/ListContinuationService.swift \
  LacEditor/Preview/MarkdownRenderer.swift \
  Verification/main.swift \
  -o .build/core-verification
.build/core-verification
```

## 版本与发布

- [CHANGELOG.md](CHANGELOG.md)：按版本记录面向用户的新增、优化和修复内容。
- [VERSIONING.md](VERSIONING.md)：分支、提交、版本号、构建号与发布流程规范。
- `VERSION`：当前 App 营销版本，与 Xcode 的 `MARKETING_VERSION` 保持一致。
- `Scripts/verify-release.sh`：执行完整发布验证。
- `Scripts/prepare-release.sh <版本号>`：同步版本、增加构建号并验证候选版本。

所有影响用户的修改都应先写入 `CHANGELOG.md` 的“未发布”部分。正式发布时按
`VERSIONING.md` 的流程生成版本提交和 `v<版本号>` 标签。

## 架构

- `App`：应用生命周期、窗口管理、窗口级状态、原生菜单和快捷键。
- `Models`：编辑文档、语言模式和文件树模型。
- `Services`：文件读写、编码选择、最近文件和 JSON 工具。
- `Editor`：AppKit 编辑器、行号、当前行、列表续写、缩进、折叠与语法高亮。
- `Preview`：本地 Markdown 转换和防抖 WebKit 预览。
- `Views`：原生窗口工具栏、可拖动标签栏、最近文件侧边栏、编辑工作区、状态栏和设置。

每个窗口由 `WindowManager` 管理独立的 `AppState` 和标签集合，最近文件在窗口间共享。
文档内容与文件状态由 `AppState` 和 `EditorDocument` 统一管理。编辑器、预览、标签和状态栏
只订阅当前文档，文件 I/O 与渲染逻辑互不依赖。

## 已实现

- 新建、打开、保存、另存为、关闭、拖拽打开和最近文件。
- TXT、Markdown、HTML、JSON、JavaScript、TypeScript、CSS、Python、Swift、Shell、
  YAML、C/C++ 和 SQL 等文本格式；默认 UTF-8，非 UTF-8 文件会要求选择编码。
- 多窗口、多标签、同窗口文件去重、未保存标记、关闭其他标签和关闭右侧标签。
- `Command+N` 新建窗口，标签可在当前窗口中拖动排序，也可拖出窗口成为独立窗口。
- 标签关闭按钮按需显示；标签过多时可在标签栏上用滚轮横向浏览，边缘淡出并自动定位当前标签。
- 关闭标签、窗口或退出前的逐文档保存确认；最后一个有内容标签关闭后保留空白标签，
  再关闭该空白标签则关闭窗口。
- 原生撤销/重做；统一的查找与替换弹窗支持 `\n`、`\t`、`\s`、`\r`、`\\` 转义字符、区分大小写和全部替换。
- 中文输入法组合、与逻辑文本行对齐的行号、当前行、自动缩进、Tab 缩进、列表自动续写和自动换行。
- 字体缩放、Markdown 标题与 JSON 容器的基础折叠。
- Markdown、JSON、HTML、JavaScript、TypeScript、CSS、Python、Swift、Shell、YAML、
  C/C++ 和 SQL 语法高亮；大文件仅高亮可视区域及缓冲区。
- Markdown 左右分栏实时预览，支持标题、列表、引用、链接、代码和表格；有序列表在嵌套项目后保留显式序号。
- JSON 格式化、压缩，以及尽可能包含行列位置的错误信息。
- Codex 风格的最近文件抽屉，收起后可从工具栏悬停临时展开；最近文件支持新窗口打开、
  重命名、Finder 定位和单项移除。
- 可拖动与拆分窗口的标签、工具栏撤销/重做、语言菜单、状态栏、深浅色主题和系统原生快捷键。
- 已接入项目内正式应用图标，提供完整 macOS AppIcon 尺寸。

主要快捷键与需求保持一致：`Command+N` 新建窗口、`Command+T` 新建标签页、
`Command+1...9` 切换对应标签页，以及
`Command+O/S/Shift+S/W`、`Command+F`、
`Command+Option+F`、`Command+G`、`Command+Shift+G`、`Command+Option+P`、
`Command+Option+L`、`Command++/-/0`，并支持 `Control+Tab` 和
`Control+Shift+Tab` 切换标签。

## 已知限制

- 第一版折叠通过“标签页 > 折叠/展开当前区块”触发，不提供行号槽折叠按钮；编辑后会展开当前折叠。
- Markdown 预览覆盖第一阶段要求的常用语法，不追求完整 CommonMark/GFM 扩展兼容。
- 超过约 50 万 UTF-16 单元的文档改为可视区高亮，以优先保证输入流畅。
- 文件夹工作区记忆、崩溃恢复、Git 和插件属于后续阶段，当前未实现。
