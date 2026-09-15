param(
  [Parameter(Mandatory = $true)][string]$TitleB64,
  [Parameter(Mandatory = $true)][string]$BodyB64,
  [string]$FootB64 = "",
  [string]$Kind = "ask",
  [int]$DurationMs = 20000,
  [string]$Sound = "1",
  [string]$LogPath = "",
  [string]$StatePath = "",
  [string]$CancelPath = "",
  [int]$OwnerPid = 0
)

# MiMoCode desktop alert renderer (Windows).
# SOURCE MUST STAY PURE ASCII: PowerShell 5.1 decodes a BOM-less file as the
# system ANSI codepage (GBK here), which mangles any in-file CJK literal.
# Every user-visible string therefore arrives base64-encoded via -TitleB64 /
# -BodyB64 / -FootB64 and is decoded here.

$ErrorActionPreference = "Stop"

function Write-NLog([string]$Message) {
  if (-not $LogPath) { return }
  try {
    Add-Content -LiteralPath $LogPath -Value ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") + " [ps] " + $Message) -Encoding UTF8
  } catch { }
}

# ---------------------------------------------------------------------------
# DPI awareness FIRST, before any UI/DC object exists. Without it the window is
# rendered at 96 DPI and bitmap-stretched by Windows, which is what makes text
# look blurry on this 200%-scaled 3072x1920 display.
# ---------------------------------------------------------------------------
Add-Type -Namespace MiMoAlert -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDPIAware();
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern uint GetConsoleTitle(System.Text.StringBuilder lpConsoleTitle, uint nSize);
[DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool IsWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
[DllImport("kernel32.dll")]
public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")]
public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
'@ -ErrorAction SilentlyContinue

$dpiMode = "none"
try {
  if ([MiMoAlert.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4))) { $dpiMode = "permonitorv2" }
} catch { }
if ($dpiMode -eq "none") {
  try { if ([MiMoAlert.Win32]::SetProcessDPIAware()) { $dpiMode = "system" } } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scale = 1.0
try {
  $screenGfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  $scale = [double]$screenGfx.DpiX / 96.0
  $screenGfx.Dispose()
} catch { $scale = 1.0 }
if ($scale -lt 1.0 -or $scale -gt 4.0) { $scale = 1.0 }

try {
  $title = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleB64))
  $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($BodyB64))
  $foot = if ($FootB64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($FootB64)) } else { "" }
} catch {
  Write-NLog ("decode failed: " + $_.Exception.Message)
  exit 1
}

Write-NLog ("dpiMode=" + $dpiMode + " scale=" + $scale)

# ---------------------------------------------------------------------------
# Scaled dimensions. A helper command (`Px 20`) only parses at statement start,
# not inside an argument list, so every value is precomputed into a variable.
# ---------------------------------------------------------------------------
$dWidth = [int][Math]::Round(460 * $scale)
$dPad = [int][Math]::Round(26 * $scale)
$dTextWidth = $dWidth - ($dPad * 2)
$dMeasureMax = [int][Math]::Round(2000 * $scale)
$dGapSmall = [int][Math]::Round(10 * $scale)
$dTitleTop = [int][Math]::Round(22 * $scale)
$dBodyTop = [int][Math]::Round(60 * $scale)
$dTitleHeight = [int][Math]::Round(32 * $scale)
$dFootHeight = [int][Math]::Round(22 * $scale)
$dBottomPad = [int][Math]::Round(22 * $scale)
$dBodyExtra = [int][Math]::Round(6 * $scale)
$dBarWidth = [int][Math]::Round(6 * $scale)
$dMinHeight = [int][Math]::Round(152 * $scale)
$dMarginX = [int][Math]::Round(22 * $scale)
$dMarginY = [int][Math]::Round(22 * $scale)
$dSlotGap = [int][Math]::Round(12 * $scale)
$dMinTopGap = [int][Math]::Round(10 * $scale)

# --- reserve a vertical slot so simultaneous alerts stack instead of overlapping ---
$mutexName = "MiMoCodeNotifyStack"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$haveLock = $false
try { $haveLock = $mutex.WaitOne(3000) } catch { $haveLock = $false }

$slot = 1
if ($StatePath) {
  try {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $count = 0
    $stamp = 0
    if (Test-Path -LiteralPath $StatePath) {
      $raw = Get-Content -LiteralPath $StatePath -Raw -ErrorAction SilentlyContinue
      if ($raw) {
        $parts = $raw.Trim() -split ","
        if ($parts.Count -eq 2) {
          $count = [int]$parts[0]
          $stamp = [int]$parts[1]
        }
        if ($DurationMs -gt 0) { $staleAfter = [int]($DurationMs / 1000) + 30 } else { $staleAfter = 900 }
        if (($now - $stamp) -gt $staleAfter) { $count = 0 }
      }
    }
    $count = $count + 1
    if ($count -gt 6) { $count = 6 }
    Set-Content -LiteralPath $StatePath -Value ($count.ToString() + "," + $now) -Encoding ASCII -ErrorAction SilentlyContinue
    $slot = $count
  } catch { $slot = 1 }
}
if ($haveLock) { try { $mutex.ReleaseMutex() } catch { } }

switch ($Kind) {
  "done" { $accent = [System.Drawing.Color]::FromArgb(255, 129, 201, 149) }
  "error" { $accent = [System.Drawing.Color]::FromArgb(255, 243, 139, 168) }
  default { $accent = [System.Drawing.Color]::FromArgb(255, 250, 179, 135) }
}

$titleFont = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$bodyFont = New-Object System.Drawing.Font("Microsoft YaHei UI", 11)
$footFont = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$measureSize = New-Object System.Drawing.Size($dTextWidth, $dMeasureMax)
$measured = [System.Windows.Forms.TextRenderer]::MeasureText(
  $body, $bodyFont, $measureSize, [System.Windows.Forms.TextFormatFlags]::WordBreak)

$dBodyHeight = $measured.Height + $dBodyExtra
$dFootTop = $dBodyTop + $dBodyHeight + $dGapSmall
$dHeight = $dFootTop + $dFootHeight + $dBottomPad
if ($dHeight -lt $dMinHeight) { $dHeight = $dMinHeight }

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x = $wa.Right - $dWidth - $dMarginX
$y = $wa.Bottom - $dHeight - $dMarginY - (($slot - 1) * ($dHeight + $dSlotGap))
if ($y -lt ($wa.Top + $dMinTopGap)) { $y = $wa.Top + $dMinTopGap }

Write-NLog ("layout screen=" + $wa.Width + "x" + $wa.Height + " form=" + $dWidth + "x" + $dHeight + " at=" + $x + "," + $y)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(255, 26, 27, 38)
$form.Size = New-Object System.Drawing.Size($dWidth, $dHeight)
$form.Location = New-Object System.Drawing.Point($x, $y)
$form.Cursor = [System.Windows.Forms.Cursors]::Hand

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.BackColor = $accent
$accentBar.Location = New-Object System.Drawing.Point(0, 0)
$accentBar.Size = New-Object System.Drawing.Size($dBarWidth, $dHeight)
$form.Controls.Add($accentBar)

$titleSize = New-Object System.Drawing.Size($dTextWidth, $dTitleHeight)
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $title
$titleLabel.Font = $titleFont
$titleLabel.ForeColor = $accent
$titleLabel.AutoSize = $false
$titleLabel.Location = New-Object System.Drawing.Point($dPad, $dTitleTop)
$titleLabel.Size = $titleSize
$titleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($titleLabel)

$bodySize = New-Object System.Drawing.Size($dTextWidth, $dBodyHeight)
$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Text = $body
$bodyLabel.Font = $bodyFont
$bodyLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 226, 228, 238)
$bodyLabel.AutoSize = $false
$bodyLabel.Location = New-Object System.Drawing.Point($dPad, $dBodyTop)
$bodyLabel.Size = $bodySize
$bodyLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($bodyLabel)

$footSize = New-Object System.Drawing.Size($dTextWidth, $dFootHeight)
$footLabel = New-Object System.Windows.Forms.Label
$footLabel.Text = $foot
$footLabel.Font = $footFont
$footLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 138, 142, 162)
$footLabel.AutoSize = $false
$footLabel.Location = New-Object System.Drawing.Point($dPad, $dFootTop)
$footLabel.Size = $footSize
$footLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($footLabel)

# ---------------------------------------------------------------------------
# Click behaviour: close this alert AND bring the owning MiMoCode window back to
# the foreground, so a click actually takes you where the decision is.
#
# The terminal window is NOT reachable by walking the process tree: a console
# app's window belongs to conhost.exe / WindowsTerminal.exe, while the ancestor
# chain here is mimo.exe -> node -> cmd -> explorer.exe (so a naive walk
# activates the user's Explorer window). Instead we read the owner's CONSOLE
# TITLE and match it against a visible top-level window title -- MiMoCode sets
# that title to the session name, and the terminal window mirrors it.
# ---------------------------------------------------------------------------
function Get-OwnerConsoleTitle {
  if ($OwnerPid -le 0) { return "" }
  try {
    [void][MiMoAlert.Win32]::FreeConsole()
    if (-not [MiMoAlert.Win32]::AttachConsole([uint32]$OwnerPid)) { return "" }
    try {
      $sb = New-Object System.Text.StringBuilder 2048
      [void][MiMoAlert.Win32]::GetConsoleTitle($sb, 2048)
      return $sb.ToString()
    } finally {
      [void][MiMoAlert.Win32]::FreeConsole()
    }
  } catch {
    return ""
  }
}

function Find-WindowByTitle([string]$Needle) {
  if (-not $Needle) { return [IntPtr]::Zero }
  try {
    $hit = Get-Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -and
        ($_.MainWindowTitle -eq $Needle -or $_.MainWindowTitle.Contains($Needle) -or $Needle.Contains($_.MainWindowTitle))
      } |
      Select-Object -First 1
    if ($hit) { return $hit.MainWindowHandle }
  } catch { }
  return [IntPtr]::Zero
}

# Last resort only: an ancestor window, but never explorer.exe (that is the app
# launcher, not the terminal).
function Get-AncestorWindow {
  if ($OwnerPid -le 0) { return [IntPtr]::Zero }
  $cur = $OwnerPid
  $hops = 0
  while ($cur -gt 0 -and $hops -lt 12) {
    $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -ne "explorer" -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
      try {
        if ([MiMoAlert.Win32]::IsWindow($proc.MainWindowHandle)) { return $proc.MainWindowHandle }
      } catch { }
    }
    $info = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $cur) -ErrorAction SilentlyContinue
    if (-not $info) { break }
    $parent = [int]$info.ParentProcessId
    if ($parent -le 0 -or $parent -eq $cur) { break }
    $cur = $parent
    $hops++
  }
  return [IntPtr]::Zero
}

function Invoke-ActivateOwner {
  try {
    $consoleTitle = Get-OwnerConsoleTitle
    $hwnd = Find-WindowByTitle $consoleTitle
    $how = "title"
    if ($hwnd -eq [IntPtr]::Zero) {
      $hwnd = Get-AncestorWindow
      $how = "ancestor"
    }
    if ($hwnd -eq [IntPtr]::Zero) {
      Write-NLog ("click: no window found (consoleTitle=[" + $consoleTitle + "])")
      return
    }
    if ([MiMoAlert.Win32]::IsIconic($hwnd)) { $null = [MiMoAlert.Win32]::ShowWindow($hwnd, 9) }
    $fg = [MiMoAlert.Win32]::GetForegroundWindow()
    $fgThread = [MiMoAlert.Win32]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $curThread = [MiMoAlert.Win32]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $curThread) {
      $attached = [MiMoAlert.Win32]::AttachThreadInput($curThread, $fgThread, $true)
    }
    $ok = [MiMoAlert.Win32]::SetForegroundWindow($hwnd)
    $null = [MiMoAlert.Win32]::BringWindowToTop($hwnd)
    if ($attached) { $null = [MiMoAlert.Win32]::AttachThreadInput($curThread, $fgThread, $false) }
    Write-NLog ("click: activated via " + $how + " hwnd=" + $hwnd + " ok=" + $ok + " title=[" + $consoleTitle + "]")
  } catch {
    Write-NLog ("activate failed: " + $_.Exception.Message)
  }
}

$script:closing = $false

function Invoke-Dismiss {
  if ($script:closing) { return }
  $script:closing = $true
  Invoke-ActivateOwner
  try { $form.Close() } catch { }
}

$dismiss = { Invoke-Dismiss }
$form.Add_Click($dismiss)
$accentBar.Add_Click($dismiss)
$titleLabel.Add_Click($dismiss)
$bodyLabel.Add_Click($dismiss)
$footLabel.Add_Click($dismiss)

$timer = $null
if ($DurationMs -gt 0) {
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(2000, $DurationMs)
  $timer.Add_Tick({ $timer.Stop(); try { $form.Close() } catch { } })
}

# Auto-dismiss as soon as the decision is made in the terminal.
$cancelTimer = $null
if ($CancelPath) {
  $cancelTimer = New-Object System.Windows.Forms.Timer
  $cancelTimer.Interval = 400
  $cancelTimer.Add_Tick({
      if (Test-Path -LiteralPath $CancelPath) {
        $cancelTimer.Stop()
        try { $form.Close() } catch { }
      }
    })
}

$form.Add_FormClosed({
    if ($timer) { $timer.Stop() }
    if ($cancelTimer) { $cancelTimer.Stop() }
    if ($CancelPath) { Remove-Item -LiteralPath $CancelPath -Force -ErrorAction SilentlyContinue }
    if ($StatePath) {
      try {
        $m2 = New-Object System.Threading.Mutex($false, $mutexName)
        $locked = $false
        try { $locked = $m2.WaitOne(2000) } catch { }
        if (Test-Path -LiteralPath $StatePath) {
          $raw = Get-Content -LiteralPath $StatePath -Raw -ErrorAction SilentlyContinue
          if ($raw) {
            $parts = $raw.Trim() -split ","
            if ($parts.Count -eq 2) {
              $c = [int]$parts[0]
              if ($c -gt 0) { $c = $c - 1 }
              Set-Content -LiteralPath $StatePath -Value ($c.ToString() + "," + $parts[1]) -Encoding ASCII -ErrorAction SilentlyContinue
            }
          }
        }
        if ($locked) { try { $m2.ReleaseMutex() } catch { } }
      } catch { }
    }
    [System.Windows.Forms.Application]::ExitThread()
})

if ($Sound -eq "1") {
  try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
}

# Create the handle early so WS_EX_NOACTIVATE is already in place when it becomes visible.
try {
  $null = $form.Handle
  $GWL_EXSTYLE = -20
  $WS_EX_NOACTIVATE = 0x08000000
  $WS_EX_TOOLWINDOW = 0x00000080
  $exStyle = [MiMoAlert.Win32]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
  $null = [MiMoAlert.Win32]::SetWindowLong($form.Handle, $GWL_EXSTYLE, ($exStyle -bor $WS_EX_NOACTIVATE -bor $WS_EX_TOOLWINDOW))
} catch {
  Write-NLog ("noactivate setup failed: " + $_.Exception.Message)
}

if ($timer) { $timer.Start() }
if ($cancelTimer) { $cancelTimer.Start() }

$prevForeground = [IntPtr]::Zero
try { $prevForeground = [MiMoAlert.Win32]::GetForegroundWindow() } catch { }

Write-NLog ("show kind=" + $Kind + " slot=" + $slot + " dur=" + $DurationMs + " pid=" + $OwnerPid + " title=" + $title)

$form.Show()

# Belt and braces: hand focus straight back if it was grabbed anyway.
try {
  if ($prevForeground -ne [IntPtr]::Zero) {
    $null = [MiMoAlert.Win32]::SetForegroundWindow($prevForeground)
  }
} catch { }

[System.Windows.Forms.Application]::Run()
Write-NLog "closed"
