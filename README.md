# mimocode-plugin-notify

MiMoCode 桌面提醒插件（Windows / macOS）：当 AI 需要你拍板、或者在等你、或者刚跑完时发出桌面提醒。Windows 使用可点击跳回终端的置顶窗口；macOS 使用系统原生通知中心，无需安装额外依赖。

> Desktop alerts for MiMoCode on Windows and macOS: topmost Windows popups or native macOS notifications for approvals, questions, keyboard input, completed turns and errors.

解决的实际问题：AI 跑着的时候你切去干别的，回来发现它早就卡在某个确认框上等了十分钟。

---

## 弹什么、什么时候弹

以下事件两端均支持；表中的存活时间仅适用于 Windows。macOS 的显示时长由系统通知设置控制。

| 触发时机 | 对应事件 | 弹窗标题 | 存活时间 |
|---|---|---|---|
| AI 要执行命令 / 申请权限 | `permission.asked` | MiMoCode · 需要你授权 | **不自动消失**，直到你在终端处理完或点击关闭 |
| AI 提问等你回答 | `question.asked` | MiMoCode · 在等你回答 | 同上 |
| 命令需要键盘输入 | `bash.interactive.asked` | MiMoCode · 需要键盘输入 | 同上 |
| 本轮任务跑完 | `session.idle` | MiMoCode · 执行完毕 | 30 秒 |
| 本轮执行出错 | `session.post` (outcome=error) | MiMoCode · 出错了 | 30 秒 |

Windows 弹窗的设计取舍：

- **不抢键盘焦点**。只给窗口加 `WS_EX_NOACTIVATE` 是**不够**的 —— WinForms 的 `Form.Show()` 用 `SW_SHOW` 显示窗口，照样会抢前台（实测：这样弹出的窗口每一次都把前台从用户的编辑器手里抢走，直到它消失）。所以窗口用的是 `Add-Type` 编译出来的 `NoActivateForm` 子类：`ShowWithoutActivation` 让 `Show()` 改用 `SW_SHOWNOACTIVATE`，`CreateParams` 保证 `WS_EX_NOACTIVATE` 从窗口创建那一刻就带上。两半缺一不可，弹出来时你正在别处打字不会被打断。
- **点击才跳转**。点弹窗会激活**发起这条提醒的那个**终端窗口，然后弹窗自己关掉。窗口是按**控制台**定位的，不按标题，所以同时开着多个终端窗口时不会串台、也不会漏跳。
- **同一个 Windows Terminal 窗口里开多个会话时，只能把该窗口抬到最前**，无法切到对应标签页（Windows Terminal 没有公开的标签页切换接口）。想让点击精确落到某个会话，请一个会话一个终端窗口。
- **授权类永不自动消失**。因为那类提醒错过了就是真卡住了。你在终端一处理完，弹窗会自己收掉（不放心的话点一下也能关）。
- **顺带解决了系统 Toast 的坑**：Windows 11 对未注册 AUMID 的 Toast 是**静默丢弃**的（`Show()` 返回成功但你什么都看不到）。这里改用自绘置顶窗口，绕不过去。

## 环境要求

- **Windows 10 / 11**（依赖 PowerShell 5.1 + WinForms + 少量 Win32 调用）
- **macOS**（使用系统自带的 `/usr/bin/osascript`，需要已登录的图形桌面会话；无需 Homebrew、terminal-notifier 或 Xcode）
- MiMoCode（`@mimo-ai/cli`）
- 其他平台（例如 Linux）记录不支持日志，不弹通知

### macOS 行为与权限

- 授权、提问、键盘输入、完成和错误通知共用原有事件开关，`sound` 和 `done_min_seconds` 同样生效。
- `ask_duration_ms` / `done_duration_ms` 仅用于 Windows；macOS 横幅或提醒样式、持续时间由系统控制，不保证持续置顶。
- 在终端处理完后，macOS 通知不会自动撤回；点击通知也不保证跳回运行 MiMoCode 的终端。这是 `osascript display notification` 的接口限制。
- 首次测试后，若没有横幅，请检查「系统设置 → 通知」中对应发送程序的通知权限（通常显示为「脚本编辑器 / Script Editor」，以系统实际条目为准），并检查专注模式。通知声音也受系统音量和通知设置控制。
- SSH、后台服务或没有图形桌面的环境不能保证显示通知；通知是在运行插件的 Mac 上发送的，不会转发到远程客户端。

## 安装

```bash
mimo plugin mimocode-plugin-notify -g
```

`-g` 表示装到全局配置，所有项目通用。装完**重启一次 MiMoCode**。

其他方式：

- TUI 里打开插件管理对话框，标题是 `Install plugin`，输入框填 `mimocode-plugin-notify`
- 手动在 `~/.config/mimocode/mimocode.jsonc` 里加：

  ```jsonc
  {
    "plugin": ["mimocode-plugin-notify"]
  }
  ```

### 从本地目录安装（未发布 / 自行改动时）

本目录中的 macOS 适配尚未发布到 npm，请通过本地目录安装，而不是安装 npm 上的旧版本。

```bash
mimo plugin /path/to/mimocode-plugin-notify -g
```

`mimo plugin` 也接受目录路径和 `.tgz`（**目录路径更稳**，tarball 形式下它会把清单路径算错）。它会读该目录的 `package.json`、探测 server 入口，然后把路径写进全局配置的 `plugin` 数组。

**两个容易踩的坑**：

- 配置里指向 `node_modules` 是没用的。MiMoCode 不从配置目录解析裸包名，而是走自己的缓存 `~/.cache/mimocode/packages/<名>@<版本>/`，那部分由 `mimo plugin` 负责填充；裸包名只有在包已发布到 npm 后才可用。
- **模块只能导出函数**（或 `{ server: 函数 }` 对象）。外部插件加载器会遍历**所有**导出并要求每个都是函数，任何一个字符串/对象常量都会让它抛 `Plugin export is not a function` 而整个插件加载失败。所以版本号、默认配置之类的常量必须留在模块内部，不要 `export`。

## 配置

首次加载时会自动生成默认配置：

```
~/.config/mimocode/mimo-notify/config.json
```

**改完即时生效，不需要重启。**

```jsonc
{
  "enabled": true,

  // 逐项开关
  "events": {
    "permission": true,   // 需要授权
    "question": true,     // AI 提问
    "interactive": true,  // 需要键盘输入
    "done": true,         // 执行完毕
    "error": true         // 执行出错
  },

  // 仅 Windows：授权类弹窗存活毫秒数。0 = 永不自动消失
  "ask_duration_ms": 0,

  // 仅 Windows："执行完毕 / 出错" 弹窗存活毫秒数
  "done_duration_ms": 30000,

  // 提示音
  "sound": true,

  // 短于这个秒数的任务不弹"执行完毕"，避免你盯着屏幕时被打扰
  "done_min_seconds": 10
}
```

> 用记事本改这个文件没问题（会正确处理 BOM），但**不要**把 JSON 写坏 —— 解析失败时会静默回退到默认值，日志里会记一条 `config read failed`。

## 排障

日志在 `~/.config/mimocode/mimo-notify/notify.log`，同时包含插件侧（`[plugin]`）和渲染脚本侧（`[ps]`）的记录，可以随时清空。

macOS 的通知日志均为 `[plugin]`，包含 `backend=osascript`、`macOS notification submitted` 或进程失败状态；不记录通知正文。`submitted` 只表示系统命令成功返回，不代表横幅已经显示。以下 `[ps]`、DPI 和终端激活排障项仅适用于 Windows。

在插件目录中可直接测试 macOS 通知（末尾 `0` 表示不播放提示音，`1` 表示播放）：

```bash
/usr/bin/osascript ./notify.applescript "MiMoCode · 测试" "macOS 通知测试，请检查通知中心。" 0
```

| 现象 | 原因 / 处理 |
|---|---|
| 完全不弹 | 看日志有没有 `plugin v… initialized`。没有 → 插件没被加载，确认已重启且配置里包含 `mimocode-plugin-notify` |
| 日志有 `notify kind=…` 但没有 `[ps]` 行 | 弹窗进程没起来。检查 `notify.ps1` 是否存在、PowerShell 是否可用 |
| 中文乱码 | 不该出现了。若出现，说明 `notify.ps1` 被以带 BOM 或无 BOM 的错误编码改过 —— 别手动编辑它 |
| 文字发虚 | 说明 DPI 感知没生效。日志里应有 `[ps] dpiMode=permonitorv2 scale=…` |
| 点击没跳回终端 | 正常时日志是 `click: activated via console hwnd=…`；后面的 `consoleHwnd=` 是发起提醒那个控制台的窗口句柄，可用来核对定位是否正确。出现 `click: no window found` 说明连控制台都取不到（例如 MiMoCode 不是从终端启动的） |
| 弹窗抢焦点 / 打字被打断 | 日志里应有 `[ps] exstyle=0x08010088 WS_EX_NOACTIVATE=True`。不是 `True` → `notify.ps1` 里那段 C# 子类没编译上，看同一次弹窗有没有 `exstyle check failed` |
| 弹窗卡住不消失 | 正常情况下终端一处理完就会收掉。点一下即可关闭 |

## 它是怎么工作的

- 通过 MiMoCode 插件的 `event` 钩子订阅 SDK 事件流（`permission.asked` / `question.asked` / `bash.interactive.asked` / `session.idle` / `*.replied`），辅以几个具名钩子（`session.pre` 建会话集、`session.userQuery.pre` 记回合起点、`experimental.text.complete` 与 `session.post` 缓存最终输出）。
- "跑完"用 `session.idle` 而不是 `session.post` —— 后者对每个 subagent 各触发一次，噪音太大。主会话通过 `session.pre` 的 `agentID` 过滤出来。
- 弹窗用 PowerShell 5.1 + WinForms 画一个无边框置顶窗口；中文一律以 **base64** 形式作为参数传入（脚本源码保持纯 ASCII，避免 PowerShell 5.1 按 ANSI 解码无 BOM 文件导致乱码）。窗口类型是 `Add-Type -TypeDefinition` 编译出的 `MiMoAlert.NoActivateForm` —— 要覆盖 `ShowWithoutActivation` / `CreateParams` 这两个 protected 成员，只有子类化这一条路，PowerShell 直接 new 一个 `Form` 是做不到的。
- 点击跳转**不靠窗口标题**：先 `AttachConsole` 到 MiMoCode 进程所在的控制台，用 `GetConsoleWindow()` 取该控制台的窗口句柄，再顺着 `GW_OWNER` 找终端窗口。经典 conhost 下这个句柄就是窗口本身（没有 owner）；Windows Terminal（ConPTY）下它是一个不在屏幕上的 `PseudoConsoleWindow`（而且 `IsWindowVisible()` 仍报 true，所以不能靠可见性判断），它的 owner 才是可见的终端窗口 —— 因此沿 owner 链取最近的一个可见窗口，没有可见的才退到最外层。标题匹配降级为兜底，并且改为遍历**所有**顶层窗口 —— `Process.MainWindowTitle` 每个进程只会报一个窗口，而一个 `WindowsTerminal.exe` 承载它的每一个窗口，这正是以前开着两个窗口时点第二个必然失效的原因。
- macOS 通过 `execFile` 调用包内 `notify.applescript`，标题与正文使用独立参数传递，不拼接 shell 命令或 AppleScript 源码；调用设置 10 秒超时，失败不影响会话继续。
- Windows 取消标记用**落盘文件**而非临时信号：`*.replied` 事件常常比弹窗进程启动早约 1 秒到达，只有文件能跨越这个时序差。macOS 不生成无用的取消标记。

## 开发验证

使用 Node.js 20+，无需安装测试依赖：

```bash
npm run check
npm test
npm pack --dry-run
```

单元测试隔离了平台、文件系统和子进程，不会修改实际配置或弹出通知；macOS 桌面显示需用上面的命令人工确认。Windows 分支有启动参数回归测试，实际 WinForms 显示需在 Windows 上验证。

## 卸载

```bash
# 从配置里移除 plugin 数组中的 mimocode-plugin-notify 后：
cd ~/.config/mimocode && bun remove mimocode-plugin-notify
```

配置和日志留在 `~/.config/mimocode/mimo-notify/`，可手动删除。

## License

MIT
