# LacEditor

LacEditor 是一款面向 macOS 26、Apple Silicon 的轻量原生文本编辑器。工程使用 SwiftUI 构建界面，以 AppKit `NSTextView` 提供编辑能力，并使用 WebKit 在本地呈现 Markdown 预览。应用不需要登录、云同步或网络权限，也不采集用户内容。

当前版本：`0.10.0 (10)`

## 构建

1. 在 macOS 26、Apple Silicon Mac 上使用 Xcode 26 打开 `LacEditor.xcodeproj`。首次构建时，
   Xcode 会按两个 `Package.resolved` 中锁定的版本解析 `swift-cmark` 依赖。
2. 选择 `LacEditor` scheme 和 `My Mac`。
3. 按 `Command+R` 构建并运行。

工程还包含 `Package.swift`，可通过命令行检查源码：

```bash
swift build
swift build -c release
swift test
```

核心 JSON、文本工具和折叠逻辑可独立验证：

```bash
swiftc \
  LacEditor/Models/EditorLanguage.swift \
  LacEditor/Models/EditorDocument.swift \
  LacEditor/Services/FileService.swift \
  LacEditor/Services/JSONFormatter.swift \
  LacEditor/Services/TextSearchService.swift \
  LacEditor/Services/TextCodecService.swift \
  LacEditor/Editor/FoldService.swift \
  LacEditor/Editor/ListContinuationService.swift \
  LacEditor/Editor/LogicalLineIndex.swift \
  LacEditor/Editor/CodeLexicalScanner.swift \
  LacEditor/Editor/DelimiterMatchingService.swift \
  LacEditor/Editor/SyntaxHighlighter.swift \
  Verification/main.swift \
  -o .build/core-verification
.build/core-verification
```

折叠布局高度、展开恢复和编辑边界可独立验证：

```bash
swiftc \
  LacEditor/Editor/FoldLayoutManager.swift \
  LacEditor/Editor/LogicalLineIndex.swift \
  Verification/FoldLayoutVerification.swift \
  -o .build/fold-layout-verification
.build/fold-layout-verification
```

完整验收（发布构建、核心逻辑、全部文件格式往返、性能基线、产物与隐私检查）运行：

```bash
./Scripts/run-acceptance.sh
```

人工 UI 验收标准和通过门槛见 [ACCEPTANCE_TESTS.md](ACCEPTANCE_TESTS.md)。脚本会另外构建
Bundle ID 隔离的 UI 验收 App，避免污染正式应用的最近文件和界面偏好。

## 版本与发布

- [CHANGELOG.md](CHANGELOG.md)：按版本记录面向用户的新增、优化和修复内容。
- [VERSIONING.md](VERSIONING.md)：分支、提交、版本号、构建号与发布流程规范。
- `VERSION`：当前 App 营销版本，与 Xcode 的 `MARKETING_VERSION` 保持一致。
- `Scripts/verify-release.sh`：执行完整发布验证。
- `Scripts/prepare-release.sh <版本号>`：同步版本、增加构建号并验证候选版本。
- `Scripts/clean-build-artifacts.sh`：只读预览项目内可再生成的构建产物；确认预览后按脚本输出的
  `--confirm <工程绝对路径>` 命令执行清理。

所有影响用户的修改都应先写入 `CHANGELOG.md` 的“未发布”部分。正式发布时按
`VERSIONING.md` 的流程生成版本提交和 `v<版本号>` 标签。

## 架构

- `App`：应用生命周期、窗口管理、窗口级状态、原生菜单和快捷键。
- `Models`：编辑文档、语言模式、文件身份和磁盘版本状态。
- `Services`：文件读写、编码选择、最近文件、JSON 工具和文本编解码。
- `Editor`：AppKit 编辑器、行号、当前行、列表续写、缩进、折叠与语法高亮。
- `Preview`：基于 `cmark-gfm` 的本地 CommonMark/GFM 转换和防抖 WebKit 预览。
- `Views`：原生窗口工具栏、可拖动标签栏、最近文件侧边栏、编辑工作区、状态栏和设置。

每个窗口由 `WindowManager` 管理独立的 `AppState` 和标签集合，最近文件在窗口间共享；
`WindowManager` 同时协调应用级文件身份，确保同一磁盘文件只存在一个可编辑实例。
主题、字体、自动换行、行号和状态栏由共享的 `AppPreferences` 管理，修改后会同步到所有窗口。
文档内容与文件状态由 `AppState` 和 `EditorDocument` 统一管理。编辑器、预览、标签和状态栏
只订阅当前文档，文件 I/O 与渲染逻辑互不依赖。

### 大文件性能策略

- UTF-8 文件的磁盘读取和解码在后台执行；20 MB 以上使用内存映射读取。超过 20 MB 或
  25 万行自动进入大文件模式，超过 50 MB 会先警告并进入超大文件保护模式。
- 大文件模式默认暂停自动换行、Markdown 预览、折叠和实时字数统计；超大文件模式同时暂停
  语法高亮。状态栏和“显示”菜单可为当前标签临时恢复，关闭标签后不写入永久设置。
- 超过 500,000 个 UTF-16 单元的内容仅计算可视区及缓冲区高亮；Token 在后台生成，颜色属性
  在主线程一次性应用，过期任务不会覆盖较新的文本或视口。
- 行号滚动刷新会合并到下一轮主线程循环；窗口只挂载当前编辑器。非活动 AppKit 会话最多
  缓存 3 个、总预算 64 MB，单会话超过 24 MB 不缓存，并响应 macOS 内存压力通知。
- 所有文档允许 TextKit 非连续跳转；超过 50 万字符后停止全文后台布局，只计算当前可见区域，
  无换行滚动停止 120 ms 后再预布局前方一个视口。保存、搜索、
  全部替换、JSON 格式化与 Markdown 渲染均在后台执行，revision 变化时丢弃旧结果。
- 常见代码语言约每 16 KiB 缓存一个词法状态检查点；相邻视口从最近检查点继续扫描，编辑时
  仅丢弃受影响位置之后的检查点，长距离跨行注释和字符串不再受固定上下文长度限制。
- 输入期间由原生 `NSTextStorage` 持有实时内容，`EditorDocument` 按需或在短暂空闲后同步完整
  快照；保存、查找、关闭和跨窗口移动前会强制同步，避免每次按键复制整份大文件。
- 未保存内容在停止输入约 2 秒后写入 `~/Library/Application Support/LacEditor/Recovery`；大文件使用
  约 5 秒防抖，应用失去焦点时立即提交最新恢复副本。正文和元数据分别原子写入，元数据通过 revision
  指向完整正文，恢复过程不会修改原文件。
- 行号、当前行和光标位置直接读取 `NSTextStorage.mutableString`；实时缩放期间正文与行号以最高
  60 Hz 同步刷新，松手后再精确布局。滚动高亮按 64 KiB 分块复用已同步的不可变文本快照，被取消的深位置扫描会
  保留词法检查点；字数统计在停止输入后再执行，减少滚动和连续输入时的重复整文扫描。
- 自动性能门禁覆盖 4 MiB / 80,000 行的 TextKit 布局与基础操作，以及 10 MB / 200,000 行
  代码的首次增量扫描、相邻视口缓存复用、10,000 次输入通知和 10,000 次行列定位。

需要分析真实 UI 性能时，在 Xcode 中选择 `Product > Profile`，使用 Instruments 的
`Points of Interest` 模板查看 `EditorPerformance` 和 `FilePerformance` 分类。工程会分别记录
  `FileOpen`、`FileSave`、`Search`、`ReplaceAll`、`JSONFormat`、`MarkdownRender`、
  `EditorSessionCreate`、`EditorSessionReattach`、`TextKitVisibleLayout`、
`SyntaxTokenize`、`SyntaxApply`、`EditorModelSync`、`LineNumberDraw` 和 `MemoryEviction`。

## 已实现

- 新建、打开、保存、另存为、关闭、拖拽打开和最近文件。
- TXT、Markdown、HTML、JSON、JavaScript、TypeScript、CSS、Python、Swift、Shell、
  YAML、C/C++ 和 SQL 等文本格式；默认 UTF-8，非 UTF-8 文件会要求选择编码。
- 多窗口、多标签、应用级文件去重、外部修改冲突保护、未保存标记、关闭其他标签和关闭右侧标签。
- `Command+N` 新建窗口，标签可在当前窗口中拖动排序，也可拖出窗口成为独立窗口。
- 标签关闭按钮按需显示；标签过多时可在标签栏上用滚轮横向浏览，边缘淡出并自动定位当前标签。
- 关闭标签、窗口或退出前的逐文档保存确认；最后一个有内容标签关闭后保留空白标签，
  再关闭该空白标签则关闭窗口。
- 正常退出默认保存独立工作区快照，下次启动恢复全部窗口、标签顺序、正文、未保存状态、选区、
  滚动位置和界面状态，不会自动写回原文件；设置中可切换为退出前逐文档检查。
- 异常退出后自动恢复未保存标签、原路径、编码、选区和滚动比例；恢复标签保持未保存状态，正常保存、
  放弃修改或退出会清理恢复副本，外部文件变化仍会触发冲突确认。
- 保存默认保留文件原编码并禁止有损转换；保存、关闭窗口和退出均使用不阻塞主线程的异步流水线。
- 原生撤销/重做；非模态的独立查找与替换窗口支持 `\n`、`\t`、`\s`、`\r`、`\\`
  转义字符、区分大小写和全部替换，窗口打开时仍可编辑正文。
- 中文输入法组合、与逻辑文本行对齐的行号、当前行、自动缩进、Tab 缩进、列表自动续写和自动换行。
- 字体缩放、Markdown 标题与 JSON 容器的基础折叠。
- Markdown、JSON、HTML、JavaScript、TypeScript、CSS、Python、Swift、Shell、YAML、
  C/C++ 和 SQL 语法高亮；大文件仅高亮可视区域及缓冲区。
- Markdown 左右分栏实时预览，使用 `cmark-gfm` 支持 CommonMark 语法，以及 GFM 表格、任务列表、
  删除线、自动链接和标签过滤；有序列表在嵌套项目后保留显式序号。
- JSON 保序格式化与压缩：只规范结构空白，保留对象字段顺序、重复键、数值和字符串转义写法；
  无效内容会尽可能显示错误行列。
- URL、Base64/Base64URL、常用 HTML 实体和 Unicode/JSON 转义的编码解码；选区可智能
  识别全部类型，未选择时检测光标所在 URL、HTML 实体和 Unicode 转义，结果通过非模态
  双栏窗口预览后再复制或替换。
- Codex 风格的文件抽屉，包含收藏夹、自定义分组和最近文件；收藏与分组支持拖动排序、
  Finder 文件拖入、跨窗口同步、失效文件重新定位，以及不触碰磁盘内容的安全移除。
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
- Markdown 预览不会执行原始 HTML，也不会放行危险链接协议；这是本地预览的安全边界。
- 超过约 50 万 UTF-16 单元的文档改为可视区高亮，以优先保证输入流畅。
- 文件夹工作区记忆、Git 和插件属于后续阶段，当前未实现。
- 50 MB 是正式性能目标；100 MB 文件采用尽力支持策略。应用会允许继续打开，但为避免持续
  无响应会默认关闭高亮、预览、换行、折叠和实时字数统计。
