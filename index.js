import { execFile, spawn } from "node:child_process"
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

// NOTE: this module must export ONLY functions (or `{ server: fn }` objects).
// MiMoCode's external-plugin loader walks every export and throws
// "Plugin export is not a function" if any export is a plain value, so all
// constants below stay module-private.
const VERSION = "0.1.0"

// ---------------------------------------------------------------------------
// Paths
//
// The renderers ship INSIDE this package, so they are resolved
// relative to the module. The legacy layout (script living in the user's
// state dir) is still honoured as a fallback.
//
// Everything writable - config, log, stacking state, cancel flags - lives in a
// single user-owned state dir. Never write into the package directory: under
// npm it is node_modules and may be read-only or wiped on reinstall.
// ---------------------------------------------------------------------------
const MODULE_DIR = dirname(fileURLToPath(import.meta.url))
const STATE_DIR = join(homedir(), ".config", "mimocode", "mimo-notify")
const CONFIG = join(STATE_DIR, "config.json")
const LOG = join(STATE_DIR, "notify.log")
const STACK_STATE = join(STATE_DIR, "stack.state")
const CANCEL_DIR = join(STATE_DIR, "cancel")

const SCRIPT = [join(MODULE_DIR, "notify.ps1"), join(STATE_DIR, "notify.ps1")].find((p) =>
  existsSync(p),
)

const IS_WINDOWS = process.platform === "win32"
const IS_MACOS = process.platform === "darwin"
const MACOS_SCRIPT = join(MODULE_DIR, "notify.applescript")
const MACOS_TIMEOUT_MS = 10000
const SYSTEM_ROOT = process.env.SystemRoot ?? "C:\\Windows"
const POWERSHELL = join(SYSTEM_ROOT, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
const CMD = join(SYSTEM_ROOT, "System32", "cmd.exe")

const SUBAGENT_AGENTS = new Set([
  "general",
  "explore",
  "summary",
  "title",
  "checkpoint-writer",
  "dream",
  "distill",
  "compaction",
])

const DEFAULTS = {
  enabled: true,
  events: { permission: true, question: true, interactive: true, done: true, error: true },
  // 0 = 一直显示，直到你在终端处理完或点击关闭
  ask_duration_ms: 0,
  done_duration_ms: 30000,
  sound: true,
  done_min_seconds: 10,
}

function ensureStateDir() {
  try {
    mkdirSync(STATE_DIR, { recursive: true })
  } catch {}
}

function log(message) {
  try {
    ensureStateDir()
    appendFileSync(LOG, `${new Date().toISOString()} [plugin] ${message}\n`)
  } catch {}
}

function config() {
  try {
    // 去掉可能的 UTF-8 BOM：记事本 / PowerShell `Set-Content -Encoding UTF8`
    // 都会写 BOM，而 JSON.parse 遇到 BOM 会抛错并让配置静默回退到默认值。
    const text = readFileSync(CONFIG, "utf8").replace(/^\uFEFF/, "")
    const raw = JSON.parse(text)
    return { ...DEFAULTS, ...raw, events: { ...DEFAULTS.events, ...(raw?.events ?? {}) } }
  } catch (error) {
    log(`config read failed (${CONFIG}): ${error}`)
    return DEFAULTS
  }
}

function ensureDefaultConfig() {
  try {
    if (existsSync(CONFIG)) return
    ensureStateDir()
    writeFileSync(CONFIG, `${JSON.stringify(DEFAULTS, null, 2)}\n`, "utf8")
    log(`created default config: ${CONFIG}`)
  } catch (error) {
    log(`could not create default config: ${error}`)
  }
}

function oneLine(value, max) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim()
  return text.length > max ? `${text.slice(0, max)}…` : text
}

function b64(value) {
  return Buffer.from(value, "utf8").toString("base64")
}

function flagPath(id) {
  const safe = String(id ?? "unknown").replace(/[^A-Za-z0-9_-]/g, "_")
  return join(CANCEL_DIR, `${safe}.flag`)
}

// 清掉遗留的取消标记（弹窗被强杀 / 超时后回不来的情况）
function pruneFlags() {
  try {
    if (!existsSync(CANCEL_DIR)) return
    const cutoff = Date.now() - 10 * 60 * 1000
    for (const name of readdirSync(CANCEL_DIR)) {
      const full = join(CANCEL_DIR, name)
      try {
        if (statSync(full).mtimeMs < cutoff) rmSync(full, { force: true })
      } catch {}
    }
  } catch {}
}

function notify({ title, body, kind, durationMs, cancelId, cfg }) {
  if (!cfg.enabled) return
  if (IS_MACOS) {
    notifyMacOS({ title, body, kind, cfg })
    return
  }
  if (!IS_WINDOWS) {
    log(`skipped (${kind}): unsupported platform ${process.platform}`)
    return
  }
  if (!SCRIPT || !existsSync(SCRIPT)) {
    log(`notify.ps1 not found - expected next to index.js or in ${STATE_DIR}`)
    return
  }
  const text = body.trim() || "请回到终端窗口查看详情。"
  const foot =
    durationMs > 0
      ? `点击此弹窗可跳回终端 · ${Math.round(durationMs / 1000)} 秒后自动消失`
      : "点击此弹窗可跳回终端 · 处理完自动消失"
  let cancelPath = ""
  if (cancelId) {
    try {
      mkdirSync(CANCEL_DIR, { recursive: true })
      cancelPath = flagPath(cancelId)
    } catch {}
  }
  log(`notify kind=${kind} dur=${durationMs} body=${oneLine(text, 160)}`)
  const psArgs = [
    "-STA",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-WindowStyle",
    "Hidden",
    "-File",
    SCRIPT,
    "-TitleB64",
    b64(title),
    "-BodyB64",
    b64(oneLine(text, 500)),
    "-FootB64",
    b64(foot),
    "-Kind",
    kind,
    "-DurationMs",
    String(durationMs),
    "-Sound",
    cfg.sound ? "1" : "0",
    "-LogPath",
    LOG,
    "-StatePath",
    STACK_STATE,
    "-OwnerPid",
    String(process.pid),
    ...(cancelPath ? ["-CancelPath", cancelPath] : []),
  ]
  try {
    // Launching the popup correctly under Bun-on-Windows took some finding:
    //   * `detached: true`  -> the child silently never executes at all
    //                          (spawn hands back a pid, "close" reports exit 0,
    //                          the script never runs).
    //   * plain spawn       -> the child DOES run, but Windows kills it the
    //                          moment the MiMoCode process exits.
    //   * `cmd /c start /b` -> verified to both launch and outlive the parent.
    const child = spawn(CMD, ["/c", "start", "", "/b", POWERSHELL, ...psArgs], {
      stdio: "ignore",
      windowsHide: true,
    })
    child.on("error", (error) => log(`child error: ${error}`))
    child.unref()
  } catch (error) {
    log(`spawn failed: ${error}`)
  }
}

// macOS owns notification lifetime and click handling. Pass content as argv,
// never as AppleScript source or a shell command, so quotes remain plain text.
function notifyMacOS({ title, body, kind, cfg }) {
  if (!existsSync(MACOS_SCRIPT)) {
    log("notify.applescript not found - expected next to index.js")
    return
  }
  const text = oneLine(body, 500) || "请回到终端窗口查看详情。"
  log(`notify kind=${kind} backend=osascript`)
  try {
    execFile(
      "/usr/bin/osascript",
      [MACOS_SCRIPT, oneLine(title, 100), text, cfg.sound ? "1" : "0"],
      { timeout: MACOS_TIMEOUT_MS, maxBuffer: 64 * 1024 },
      (error) => {
        // execFile's error.message includes argv (possibly private content).
        // Log only process status; exit 0 means submitted, not visibly shown.
        if (error) {
          log(`macOS notification failed code=${error.code ?? "unknown"} signal=${error.signal ?? "none"}`)
        } else {
          log("macOS notification submitted")
        }
      },
    )
  } catch {
    log("macOS notification launch failed")
  }
}

export const MimoNotifyPlugin = async () => {
  ensureDefaultConfig()
  const boot = config()
  const scriptState = (IS_MACOS ? existsSync(MACOS_SCRIPT) : SCRIPT) ? "found" : "MISSING"
  log(
    `plugin v${VERSION} initialized (platform=${process.platform} script=${scriptState} ` +
      `state=${STATE_DIR})`,
  )
  log(
    `config enabled=${boot.enabled} ask=${boot.ask_duration_ms} done=${boot.done_duration_ms} ` +
      `done_min_s=${boot.done_min_seconds} sound=${boot.sound} events=${JSON.stringify(boot.events)}`,
  )
  pruneFlags()

  const finalText = new Map()
  const turnStart = new Map()
  const primary = new Set()
  const lastIdle = new Map()
  const suppressIdle = new Map()

  // `refresh` 必须为 true 才能覆盖已有的回合起点：session.pre 只在还没有起点时
  // 兜底，session.userQuery.pre 的 step 0 才是权威来源 —— 否则一个被抑制的短回合
  // 会把起点永远钉在过去，done_min_seconds 对后续每个回合都失效。
  const markTurnStart = (sessionID, refresh = false) => {
    if (sessionID && (refresh || !turnStart.has(sessionID))) turnStart.set(sessionID, Date.now())
  }

  const questionSummary = (questions) => {
    const first = questions?.[0]
    if (!first) return "AI 向你提出了一个问题。"
    const parts = [first.header, first.question].filter(
      (value) => typeof value === "string" && value.trim(),
    )
    return parts.join("：") || "AI 向你提出了一个问题。"
  }

  // 决策已经在终端做出 -> 写下标记文件，弹窗轮询到就会自己收掉。
  // 必须是"写文件"而不是"删文件"：reply 事件常常比弹窗进程启动还早（约 700ms），
  // 只有落盘的标记能跨越这个时间差。弹窗关闭时会删掉自己的标记。
  const markCancelled = (id) => {
    // Native macOS notifications cannot be withdrawn through osascript.
    if (!IS_WINDOWS || !id) return
    try {
      mkdirSync(CANCEL_DIR, { recursive: true })
      writeFileSync(flagPath(id), "")
      log(`cancel flag written for ${id}`)
    } catch (error) {
      log(`cancel flag write failed: ${error}`)
    }
  }

  return {
    "session.pre": async (input) => {
      try {
        if (!SUBAGENT_AGENTS.has(input.agentID)) {
          primary.add(input.sessionID)
          markTurnStart(input.sessionID)
        }
      } catch (error) {
        log(`session.pre failed: ${error}`)
      }
    },

    "session.userQuery.pre": async (input) => {
      try {
        if (input.step === 0) markTurnStart(input.sessionID, true)
      } catch {}
    },

    "experimental.text.complete": async (input, output) => {
      try {
        if (input.sessionID && output.text) finalText.set(input.sessionID, output.text)
      } catch {}
    },

    "session.post": async (input) => {
      try {
        if (input.sessionID && input.finalText) finalText.set(input.sessionID, input.finalText)
        const cfg = config()
        if (input.outcome !== "error" || !cfg.events.error) return
        if (!primary.has(input.sessionID)) return
        suppressIdle.set(input.sessionID, Date.now() + 5000)
        notify({
          title: "MiMoCode · 出错了",
          body: input.error ? oneLine(input.error, 300) : "本轮执行失败，请回到终端查看原因。",
          kind: "error",
          durationMs: cfg.done_duration_ms,
          cfg,
        })
      } catch (error) {
        log(`session.post failed: ${error}`)
      }
    },

    event: async ({ event }) => {
      try {
        const cfg = config()
        if (!cfg.enabled) return
        const props = event?.properties ?? {}

        switch (event?.type) {
          case "permission.asked": {
            if (!cfg.events.permission) return
            pruneFlags()
            const target = [props.permission, ...(props.patterns ?? [])].filter(Boolean).join(" · ")
            notify({
              title: "MiMoCode · 需要你授权",
              body: `${target || "AI 请求一项权限"}\n请回到终端批准或拒绝。`,
              kind: "ask",
              durationMs: cfg.ask_duration_ms,
              cancelId: props.id,
              cfg,
            })
            return
          }

          case "question.asked": {
            if (!cfg.events.question) return
            pruneFlags()
            notify({
              title: "MiMoCode · 在等你回答",
              body: `${questionSummary(props.questions)}\n请回到终端选择或输入答案。`,
              kind: "ask",
              durationMs: cfg.ask_duration_ms,
              cancelId: props.id,
              cfg,
            })
            return
          }

          case "bash.interactive.asked": {
            if (!cfg.events.interactive) return
            pruneFlags()
            const what = [props.description, props.command].filter(Boolean).join("\n")
            notify({
              title: "MiMoCode · 需要键盘输入",
              body: `${what || "AI 正在等待终端交互输入"}\n请回到终端输入。`,
              kind: "ask",
              durationMs: cfg.ask_duration_ms,
              cancelId: props.id,
              cfg,
            })
            return
          }

          // 在终端处理完之后，自动收掉对应的弹窗
          case "permission.replied":
          case "question.replied":
          case "question.rejected": {
            markCancelled(props.requestID)
            return
          }

          case "bash.interactive.replied": {
            markCancelled(props.id)
            return
          }

          case "session.idle": {
            if (!cfg.events.done) return
            const sessionID = props.sessionID
            if (!sessionID || !primary.has(sessionID)) return
            const now = Date.now()
            if ((suppressIdle.get(sessionID) ?? 0) > now) return
            if (now - (lastIdle.get(sessionID) ?? 0) < 3000) return
            const started = turnStart.get(sessionID) ?? 0
            const elapsed = started ? now - started : -1
            if (started && elapsed < (cfg.done_min_seconds ?? 0) * 1000) {
              log(`idle suppressed session=${sessionID} elapsed=${elapsed}ms`)
              turnStart.delete(sessionID)
              return
            }

            lastIdle.set(sessionID, now)
            primary.delete(sessionID)
            turnStart.delete(sessionID)
            suppressIdle.delete(sessionID)
            const text = finalText.get(sessionID) ?? ""
            finalText.delete(sessionID)
            notify({
              title: "MiMoCode · 执行完毕",
              body: text ? oneLine(text, 300) : "本轮任务已结束，等待你的下一步指令。",
              kind: "done",
              durationMs: cfg.done_duration_ms,
              cfg,
            })
            return
          }
        }
      } catch (error) {
        log(`event hook failed: ${error}`)
      }
    },
  }
}

export default MimoNotifyPlugin
