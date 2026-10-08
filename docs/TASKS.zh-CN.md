# iNeovim — 任务计划

基于 `README.md` 中的架构设计整理的逐步开发计划。任务编号格式为
`T<阶段>.<序号>`,按阶段顺序排列,每个阶段的任务依赖前一阶段的完成。每个
任务的粒度以一次闲余时间能完成为准。每个任务完成后在 Xcode 中验证(不走
命令行构建)。

- 英文版:`TASKS.md`
- 约定:遵循 `AGENTS.md`(不在 main 分支提交、不用 Metal、不擅自引入第三方
  依赖)。

## 阶段 1 — 基础设施

- **T1.1** 用 `os.Logger` 建立结构化日志(类别:`rpc`、`render`、`input`、
  `app`)。后续所有阶段的调试都依赖它。
- **T1.2** Neovim 发现机制:定位 `nvim` 二进制(配置覆盖 → `PATH` → 常见
  路径如 `/opt/homebrew/bin`、`/usr/local/bin`),读取版本
  (`nvim --version`)以校验最低 API 级别。
- **T1.3** 确定并记录 `ext_multigrid` 策略:v1 用单 grid,但所有 redraw
  处理保留 grid id,为将来开启 multigrid 留余地。
- **T1.4** 应用生命周期:内嵌 `nvim` 随 App 启动/退出(正常退出时干净
  清理,崩溃时强杀)。
- **T1.5** 项目卫生:添加 `.gitignore`,排除 `xcuserdata/` 等用户级 Xcode
  状态文件。
- **T1.6** Sandbox 权限审查:已通过**移除 App Sandbox** 解决
  (`ENABLE_APP_SANDBOX = NO`)。在 sandbox 下子进程 `nvim` 根本无法被定位
  (窗口保持空白),也无法读取 `~/.config/nvim` 或项目文件;`user-selected-files`
  无法覆盖真实编辑器的工作流。Release 构建保留 hardened runtime。

## 阶段 2 — MessagePack codec

手写,不引第三方依赖。纯函数、无状态、可测试。

- **T2.1** 定义 `Value` 枚举:nil、bool、int、uint、float、string、
  binary、array、map、ext。
- **T2.2** 编码器:`Value` → 字节,覆盖全部 msgpack 类型。
- **T2.3** 增量解码器:维护字节缓冲区,逐个解析对象;数据不足时返回
  "需要更多字节"(stdio 没有长度前缀)。
- **T2.4** 将 ext 类型 0/1/2 映射为强类型 `Buffer` / `Window` / `Tabpage`
  句柄。
- **T2.5** codec 往返测试(需要在 Xcode 中添加 XCTest target——项目目前
  没有测试 target)。

## 阶段 3 — RPC 层

- **T3.1** `NvimProcess`:用 stdin/stdout/stderr pipes 启动
  `nvim --embed`;stderr 转发到 `rpc` 日志。
- **T3.2** 读循环:后台 `Task` 持续读取 stdout,喂给增量解码器。
- **T3.3** `RPCSession` actor:msgid 分配、基于 checked continuation 的
  请求/响应配对、`func call(_:params:) async throws -> Value`。
- **T3.4** 通知分发:将 msgpack-RPC 通知路由到已注册的处理器。
- **T3.5** 失败传播:进程退出或管道 EOF 时,让所有挂起的 continuation
  失败,并通知 UI 层。
- **T3.6** 握手:启动时调用 `nvim_get_api_info`,保存 channel id,校验
  API 兼容性。
- **T3.7** `NvimClient`:在 `RPCSession` 之上提供类型化便捷 API
  (`nvim_ui_attach`、`nvim_input`、`nvim_input_mouse`、`nvim_command`、
  `nvim_call_atomic`、`nvim_ui_try_resize` 等)。

## 阶段 4 — UI 协议与网格模型

- **T4.1** 将 `redraw` 通知解析为强类型事件枚举:`gridLine`、
  `gridScroll`、`gridClear`、`gridResize`、`cursorGoto`、`hlAttrDefine`、
  `defaultColorsSet`、`modeChange`、`flush` 等。
- **T4.2** 高亮模型:按 attr id 存储 `HlAttr`,解析前景/背景/special 颜色
  及文本属性。
- **T4.3** 网格模型:单元格存储,应用 `grid_line`、`grid_scroll`、
  `grid_clear`、`grid_resize`。
- **T4.4** 尺寸联动:视图 resize → 重算行列数 → `nvim_ui_try_resize`
  (resize 过程中做防抖)。
- **T4.5** 模式与光标状态跟踪(`mode_change`、`cursor_goto`、
  `mode_info_set` 的光标形状)。
- **T4.6** 以 `AsyncStream` 形式把事件流暴露给渲染层(单消费者,不在主
  actor 上)。

## 阶段 5 — 渲染(Core Text + CALayer)

- **T5.1** 字体管线:可配置 `NSFont`,单元格宽高度量,ascent/descent 用于
  基线定位。
- **T5.2** 渲染视图骨架:layer-backed 自定义 `NSView`,用默认颜色填充
  背景。
- **T5.3** 单元格渲染器:按样式 run 构建 `CTLine`;应用 `HlAttr` 的粗体、
  斜体、下划线、undercurl、删除线、fg/bg/sp。
- **T5.4** 合字:通过 Core Text 对连续 run 整形,使合字(Fira Code 等)
  正确渲染。
- **T5.5** 宽字符:双宽与组合字符正确占用单元格(wcwidth 式处理,与
  Neovim 的单元格模型对齐)。
- **T5.6** 按模式渲染光标(块/横线/竖线,宽度百分比取自
  `mode_info_set`),支持闪烁。
- **T5.7** 脏区合并:每个 `flush` 批量应用 `grid_line` 更新,只重绘最小
  矩形。
- **T5.8** Retina 处理:`contentsScale`、单元格矩形像素对齐。
- **T5.9** 外观:深浅色模式与 `guibg` 驱动的背景处理。

## 阶段 6 — 输入

- **T6.1** `KeyInputHandler`:`keyDown(with:)` → Neovim 键码记法,用
  `charactersIgnoringModifiers` + modifier 状态组装;完整的特殊键映射表
  (`<BS>`、`<CR>`、`<Esc>`、方向键、功能键等)。
- **T6.2** Cmd 处理:`performKeyEquivalent` 优先服务 App 快捷键;其余
  Cmd 组合可选透传为 `<D->`(可配置)。
- **T6.3** `macosOptionAsMeta` 设置项:Option 作为 `<M->` 或保持系统
  字符行为。
- **T6.4** `IMEHandler`:完整实现 `NSTextInputClient` 协议
  (`insertText`、`setMarkedText`、`hasMarkedText`、`unmarkText`、
  `selectedRange`、`attributedSubstringForProposedRange` 等)。
- **T6.5** 预编辑文本体验:在光标处绘制 marked text(带下划线);实现
  `firstRect(forCharacterRange:)`,使输入法候选窗贴住光标(验证
  view → window → screen 坐标转换)。
- **T6.6** `MouseHandler`:按下/拖拽/抬起 → `nvim_input_mouse`(拖拽即
  可视选择);modifier + 点击组合。
- **T6.7** 统一输入流:所有 handler 产出单一的 `InputEvent` 流进入
  `NvimClient`。
- **T6.8** 键盘布局边缘情况:dead keys 与非美式布局。

## 阶段 7 — 滚动与动画

- **T7.1** `ScrollController`:触控板 delta 与 `NSEventPhase`
  (began/changed/ended/momentum);传统滚轮的动量由 GUI 补出。
- **T7.2** 像素偏移层:网格内容放入 `CALayer`,用 `CADisplayLink` 驱动的
  动画器更新视觉偏移。
- **T7.3** 逻辑同步:累积像素 delta → 折算整行 → 发送滚动给 Neovim;应用
  收到的 `grid_scroll` 事件更新网格。
- **T7.4** 偏移限幅:视觉领先最多一屏,快速滚动不会露出空白。
- **T7.5** 光标滑动:用 ~50–100ms 插值动画移动光标,而非瞬移。
- **T7.6** 动画调优:曲线与 120Hz ProMotion 行为。

## 阶段 8 — 应用外壳(SwiftUI)

- **T8.1** 替换模板 `ContentView`:窗口外壳通过 `NSViewRepresentable`
  承载渲染视图。
- **T8.2** 标签页:决定用 Neovim tabpage 还是原生窗口 tab;实现所选方案。
- **T8.3** 设置界面:字体/字号、`macosOptionAsMeta`、滚动/光标动画开关。
- **T8.4** 原生菜单栏:标准应用菜单 + Neovim 相关命令。
- **T8.5** 窗口标题取自 `set_title` redraw 事件。
- **T8.6** 文件打开:支持"打开方式"/拖到图标 → 在已运行实例中打开。
- **T8.7** 内嵌 nvim 终端可用性检查(依赖 T1.6 权限)。

## 阶段 9 — 打磨与发布

- **T9.1** 错误呈现:nvim 崩溃/退出对话框,提供重启选项。
- **T9.2** 用 Instruments 做性能分析:渲染热路径、RPC 吞吐、滚动帧节奏。
- **T9.3** `Assets.xcassets` 中添加应用图标。
- **T9.4** 将 `devplaceholder` bundle ID 前缀替换为真实的反域名标识。
- **T9.5** 选定许可证并添加 `LICENSE` 文件;同步更新两份 README。
- **T9.6** 分发:签名、公证,以及基于 Xcode archive 的发布流程。
- **T9.7** 最终文档:截图、安装说明,更新 `README.md` /
  `README.zh-CN.md` 的状态。
