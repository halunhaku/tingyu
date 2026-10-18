param(
  [Parameter(Mandatory=$true)][string]$AppDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [string[]]$Routes = @('/library/songs','/library/albums','/library/artists','/library/playlists','/favorites','/search','/sources','/settings','/ai','/queue','/lyrics','/stage'),
  [int]$Width = 1440,
  [int]$Height = 900,
  # 指定后会将 Flutter 子窗口的客户区精确校准到这两个物理像素尺寸。
  [int]$ClientWidth = 0,
  [int]$ClientHeight = 0,
  # 0 表示不校验；视觉门禁必须显式传入并精确匹配。
  [double]$ExpectedDpiScale = 0,
  [int]$WaitSeconds = 8,
  # 走查用：覆盖主题 / 密度（只影响本次进程，不写回用户设置）。
  [ValidateSet('system','dark','light')][string]$Theme = 'system',
  [ValidateSet('comfortable','compact')][string]$Density = 'comfortable',
  [ValidateSet('normal','empty','error','unknown','long','failure','syncing','relogin')][string]$PreviewState = 'normal',
  [ValidateRange(1.0,3.0)][double]$PreviewScale = 1,
  # fixture 使用仓库内固定封面；none 用一个不存在的绝对路径明确关闭封面。
  [ValidateSet('fixture','none')][string]$PreviewCover = 'fixture'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TingyuShotNative {
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attribute, ref int value, int size);
  public struct Rect { public int Left, Top, Right, Bottom; }
  public struct Point { public int X, Y; }
}
'@
[void][TingyuShotNative]::SetThreadDpiAwarenessContext([IntPtr](-4))

# 一段本地静音 WAV：让队列有真实内容（封面舞台、传输条、队列行都不是空态），
# 又不碰任何网络来源，也不需要用户的曲库。
$tone = Join-Path $OutputDirectory 'shot-tone.wav'
$writer = [IO.BinaryWriter]::new([IO.File]::Create($tone))
try {
  $sampleRate = 8000
  $samples = $sampleRate * 3
  $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
  $writer.Write([int](36 + $samples * 2))
  $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
  $writer.Write([int]16)
  $writer.Write([int16]1); $writer.Write([int16]1)
  $writer.Write([int]$sampleRate); $writer.Write([int]($sampleRate * 2))
  $writer.Write([int16]2); $writer.Write([int16]16)
  $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
  $writer.Write([int]($samples * 2))
  for ($i = 0; $i -lt $samples; $i++) { $writer.Write([int16]0) }
} finally {
  $writer.Dispose()
}

# 截取 Flutter 子窗口的客户区。
function Save-ClientShot($child, $path) {
  $rect = [TingyuShotNative+Rect]::new()
  [void][TingyuShotNative]::GetClientRect($child, [ref]$rect)
  $origin = [TingyuShotNative+Point]::new()
  [void][TingyuShotNative]::ClientToScreen($child, [ref]$origin)
  $bitmap = [Drawing.Bitmap]::new($rect.Right, $rect.Bottom)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size)
    $bitmap.Save($path)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Disable-WindowRounding($window) {
  # Windows 11 默认会把顶层窗口边缘圆角化；客户区截图会透出桌面内容。
  # 固定视觉窗口关闭该 DWM 装饰，保证截图只包含 Flutter 客户区。
  $preference = 1 # DWMWCP_DONOTROUND
  $result = [TingyuShotNative]::DwmSetWindowAttribute($window, 33, [ref]$preference, 4)
  if ($result -ne 0) {
    throw ('Could not disable DWM rounded corners; HRESULT=0x{0:X8}' -f $result)
  }
}

function Get-WindowSize($window) {
  $rect = [TingyuShotNative+Rect]::new()
  if (![TingyuShotNative]::GetWindowRect($window, [ref]$rect)) {
    throw 'GetWindowRect failed.'
  }
  return [pscustomobject]@{
    Width = $rect.Right - $rect.Left
    Height = $rect.Bottom - $rect.Top
  }
}

function Get-ClientSize($child) {
  $rect = [TingyuShotNative+Rect]::new()
  if (![TingyuShotNative]::GetClientRect($child, [ref]$rect)) {
    throw 'GetClientRect failed.'
  }
  return [pscustomobject]@{
    Width = $rect.Right
    Height = $rect.Bottom
  }
}

function Set-ExactClientSize($window, $child, [int]$targetWidth, [int]$targetHeight) {
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    $outer = Get-WindowSize $window
    $client = Get-ClientSize $child
    if ($client.Width -eq $targetWidth -and $client.Height -eq $targetHeight) {
      return
    }
    $nextWidth = $outer.Width + ($targetWidth - $client.Width)
    $nextHeight = $outer.Height + ($targetHeight - $client.Height)
    if (![TingyuShotNative]::SetWindowPos(
      $window,
      [IntPtr](-1),
      0,
      0,
      $nextWidth,
      $nextHeight,
      0x0040
    )) {
      throw 'SetWindowPos failed while calibrating the client area.'
    }
    Start-Sleep -Milliseconds 160
  }
  $actual = Get-ClientSize $child
  throw "Could not calibrate client area to ${targetWidth}x${targetHeight}; got $($actual.Width)x$($actual.Height)."
}

if (($ClientWidth -eq 0) -ne ($ClientHeight -eq 0)) {
  Write-Error 'ClientWidth and ClientHeight must be provided together.'
  exit 1
}

$fixtureCover = [IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot '../app/tool/fixtures/voice-archive-cover.png')
)
$previewCoverPath = if ($PreviewCover -eq 'fixture') {
  if (!(Test-Path -LiteralPath $fixtureCover -PathType Leaf)) {
    Write-Error "Fixture cover not found: $fixtureCover"
    exit 1
  }
  $fixtureCover
} else {
  Join-Path $OutputDirectory ('.tingyu-no-cover-' + [Guid]::NewGuid().ToString('N') + '.png')
}

$captureRecords = [Collections.Generic.List[object]]::new()
$exitCode = 0
try {
  $previousRoute = $env:TINGYU_DEBUG_ROUTE
  $previousSources = $env:TINGYU_DEBUG_SOURCES
  $previousTheme = $env:TINGYU_DEBUG_THEME
  $previousDensity = $env:TINGYU_DEBUG_DENSITY
  $previousPreviewState = $env:TINGYU_PREVIEW_STATE
  $previousPreviewScale = $env:TINGYU_PREVIEW_SCALE
  $previousPreviewCover = $env:TINGYU_PREVIEW_COVER
  if ($Theme -ne 'system') { $env:TINGYU_DEBUG_THEME = $Theme } else { $env:TINGYU_DEBUG_THEME = $null }
  if ($Density -ne 'comfortable') { $env:TINGYU_DEBUG_DENSITY = $Density } else { $env:TINGYU_DEBUG_DENSITY = $null }
  $env:TINGYU_PREVIEW_STATE = $PreviewState
  $env:TINGYU_PREVIEW_SCALE = if ($PreviewScale -eq 1) {
    $null
  } else {
    $PreviewScale.ToString([Globalization.CultureInfo]::InvariantCulture)
  }
  $env:TINGYU_PREVIEW_COVER = $previewCoverPath
  foreach ($route in $Routes) {
    $env:TINGYU_DEBUG_ROUTE = $route
    $env:TINGYU_DEBUG_SOURCES = $tone
    $name = ($route.TrimStart('/') -replace '[^A-Za-z0-9]+', '-')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'root' }
    $process = Start-Process -FilePath (Join-Path $AppDirectory 'tingyu.exe') -WorkingDirectory $AppDirectory -PassThru
    try {
      Start-Sleep -Seconds $WaitSeconds
      $process.Refresh()
      if ($process.HasExited) { throw "启动失败（$route）：退出码 $($process.ExitCode)" }
      $window = $process.MainWindowHandle
      if ($window -eq [IntPtr]::Zero) {
        $windowDeadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
          Start-Sleep -Milliseconds 100
          $process.Refresh()
          if ($process.HasExited) { throw "启动后立即退出（$route）：退出码 $($process.ExitCode)" }
          $window = $process.MainWindowHandle
        } while ($window -eq [IntPtr]::Zero -and (Get-Date) -lt $windowDeadline)
      }
      if ($window -eq [IntPtr]::Zero) { throw "主窗口句柄未出现（$route）" }
      $initialWidth = if ($ClientWidth -gt 0) { $ClientWidth + 64 } else { $Width }
      $initialHeight = if ($ClientHeight -gt 0) { $ClientHeight + 96 } else { $Height }
      [void][TingyuShotNative]::SetWindowPos($window, [IntPtr](-1), 0, 0, $initialWidth, $initialHeight, 0x0040)
      [void][TingyuShotNative]::SetForegroundWindow($window)
      Start-Sleep -Seconds 4
      $child = [TingyuShotNative]::GetWindow($window, 5)
      if ($child -eq [IntPtr]::Zero) { throw "Flutter 子窗口未找到（$route）" }
      if ($ClientWidth -gt 0) {
        Set-ExactClientSize $window $child $ClientWidth $ClientHeight
        [void][TingyuShotNative]::SetForegroundWindow($window)
        Start-Sleep -Seconds 1
      }
      Disable-WindowRounding $window
      $scale = [TingyuShotNative]::GetDpiForWindow($child) / 96.0
      $client = [TingyuShotNative+Rect]::new()
      [void][TingyuShotNative]::GetClientRect($child, [ref]$client)
      if ($ExpectedDpiScale -gt 0 -and [Math]::Abs($scale - $ExpectedDpiScale) -gt 0.01) {
        throw "DPI 缩放不匹配（$route）：期望 $ExpectedDpiScale，实际 $scale"
      }
      # 将指针停在 (0,0) 以清除客户区 hover 状态；截图内容本身由
      # 固定入口、客户区尺寸和关闭 DWM 圆角共同约束。
      [void][TingyuShotNative]::SetCursorPos(0, 0)
      Start-Sleep -Milliseconds 350
      $cursor = [TingyuShotNative+Point]::new()
      [void][TingyuShotNative]::GetCursorPos([ref]$cursor)
      Write-Host ("截图 $route → $name.png：$($client.Right)x$($client.Bottom) 物理像素，DPI 缩放 $scale")
      $capturePath = Join-Path $OutputDirectory "$name.png"
      Save-ClientShot $child $capturePath
      $captureRecords.Add([ordered]@{
        route = $route
        file = "$name.png"
        clientWidth = $client.Right
        clientHeight = $client.Bottom
        dpiScale = $scale
        expectedDpiScale = $ExpectedDpiScale
        theme = $Theme
        density = $Density
        previewState = $PreviewState
        previewScale = $PreviewScale
        previewCover = $PreviewCover
        previewCoverPath = $previewCoverPath
        animationsDisabled = $true
        captureMethod = 'CopyFromScreen with DWM rounded corners disabled'
        windowCorners = 'do-not-round'
        cursorPosition = [ordered]@{ x = $cursor.X; y = $cursor.Y }
        sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash.ToLowerInvariant()
      })
    } finally {
      if (!$process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
      }
    }
  }
} catch {
  Write-Error $_
  $exitCode = 1
} finally {
  $env:TINGYU_DEBUG_ROUTE = $previousRoute
  $env:TINGYU_DEBUG_SOURCES = $previousSources
  $env:TINGYU_DEBUG_THEME = $previousTheme
  $env:TINGYU_DEBUG_DENSITY = $previousDensity
  $env:TINGYU_PREVIEW_STATE = $previousPreviewState
  $env:TINGYU_PREVIEW_SCALE = $previousPreviewScale
  $env:TINGYU_PREVIEW_COVER = $previousPreviewCover
  [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    appDirectory = [IO.Path]::GetFullPath($AppDirectory)
    requestedClientWidth = $ClientWidth
    requestedClientHeight = $ClientHeight
    expectedDpiScale = $ExpectedDpiScale
    captures = @($captureRecords)
  } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (
    Join-Path $OutputDirectory 'capture-metadata.json'
  )
}
exit $exitCode
