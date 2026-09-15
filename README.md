# mimocode-plugin-notify

MiMoCode 桌面提醒插件（Windows）：当 AI 需要你拍板、或者在等你、或者刚跑完时，在屏幕右下角弹出一个**置顶窗口**；点一下就能把运行 MiMoCode 的那个终端窗口拉到前台。

> Desktop alerts for MiMoCode on Windows. A topmost popup appears when the agent needs your approval, asks a question, waits on keyboard input, or finishes a turn — click it to jump back to the terminal.

解决的实际问题：AI 跑着的时候你切去干别的，回来发现它早就卡在某个确认框上等了十分钟。

---

## 弹什么、什么时候弹

| 触发时机 | 对应事件 | 弹窗标题 | 存活时间 |
|---|---|---|---|
| AI 要执行命令 / 申请权限 | `permission.asked` | MiMoCode · 需要你授权 | **不自动消失**，直到你在终端处理完或点击关闭 |
| AI 提问等你回答 | `question.asked` | MiMoCode · 在等你回答 | 同上 |
| 命令需要键盘输入 | `bash.interactive.asked` | MiMoCode · 需要键盘输入 | 同上 |
| 本轮任务跑完 | `session.idle` | MiMoCode · 执行完毕 | 30 秒 |
| 本轮执行出错 | `session.post` (outcome=error) | MiMoCode · 出错了 | 30 秒 |

几点设计取舍：

- **不抢键盘焦点**。用的是 `WS_EX_NOACTIVATE` 置顶窗口，弹出来时不会打断你正在别处打字。
- **点击才跳转**。点弹窗会激活对应的终端窗口，然后弹窗自己关掉。
- **授权类永不自动消失**。因为那类提醒错过了就是真卡住了。你在终端一处理完，弹窗会自己收掉（不放心的话点一下也能关）。
- **顺带解决了系统 Toast 的坑**：Windows 11 对未注册 AUMID 的 Toast 是**静默丢弃**的（`Show()` 返回成功但你什么都看不到）。这里改用自绘置顶窗口，绕不过去。

## 环境要求

- **Windows 10 / 11**（依赖 PowerShell 5.1 + WinForms + 少量 Win32 调用）
- MiMoCode（`@mimo-ai/cli`）
- 非 Windows 平台装了也不会报错，只是记一条日志后什么都不做

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

  // 授权类弹窗存活毫秒数。0 = 永不自动消失（推荐，直到你处理完或点击）
  "ask_duration_ms": 0,

  // "执行完毕 / 出错" 弹窗存活毫秒数
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

| 现象 | 原因 / 处理 |
|---|---|
| 完全不弹 | 看日志有没有 `plugin v… initialized`。没有 → 插件没被加载，确认已重启且配置里包含 `mimocode-plugin-notify` |
| 日志有 `notify kind=…` 但没有 `[ps]` 行 | 弹窗进程没起来。检查 `notify.ps1` 是否存在、PowerShell 是否可用 |
| 中文乱码 | 不该出现了。若出现，说明 `notify.ps1` 被以带 BOM 或无 BOM 的错误编码改过 —— 别手动编辑它 |
| 文字发虚 | 说明 DPI 感知没生效。日志里应有 `[ps] dpiMode=permonitorv2 scale=…` |
| 点击没跳回终端 | 日志里会有 `click: activated via …` 或 `click: no window found`。后者通常是终端窗口标题被改动过 |
| 弹窗卡住不消失 | 正常情况下终端一处理完就会收掉。点一下即可关闭 |

## 它是怎么工作的

- 通过 MiMoCode 插件的 `event` 钩子订阅 SDK 事件流（`permission.asked` / `question.asked` / `bash.interactive.asked` / `session.idle` / `*.replied`），辅以几个具名钩子（`session.pre` 建会话集、`session.userQuery.pre` 记回合起点、`experimental.text.complete` 与 `session.post` 缓存最终输出）。
- "跑完"用 `session.idle` 而不是 `session.post` —— 后者对每个 subagent 各触发一次，噪音太大。主会话通过 `session.pre` 的 `agentID` 过滤出来。
- 弹窗用 PowerShell 5.1 + WinForms 画一个无边框置顶窗口；中文一律以 **base64** 形式作为参数传入（脚本源码保持纯 ASCII，避免 PowerShell 5.1 按 ANSI 解码无 BOM 文件导致乱码）。
- 取消标记用**落盘文件**而非临时信号：`*.replied` 事件常常比弹窗进程启动早约 1 秒到达，只有文件能跨越这个时序差。

## 卸载

```bash
# 从配置里移除 plugin 数组中的 mimocode-plugin-notify 后：
cd ~/.config/mimocode && bun remove mimocode-plugin-notify
```

配置和日志留在 `~/.config/mimocode/mimo-notify/`，可手动删除。

## License

MIT
