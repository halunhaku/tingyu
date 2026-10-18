param(
  [Parameter(Mandatory=$true)][string]$AppDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [string[]]$Routes = @('/library/songs','/library/albums','/library/artists','/library/playlists','/favorites','/search','/sources','/settings','/ai','/queue','/lyrics','/stage'),
  [int]$Width = 1440,
  [int]$Height = 900,
  [int]$WaitSeconds = 8,
  # 走查用：覆盖主题 / 密度（只影响本次进程，不写回用户设置）。
  [ValidateSet('system','dark','light')][string]$Theme = 'system',
  [ValidateSet('comfortable','compact')][string]$Density = 'comfortable'
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
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
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
} finally { $writer.Dispose() }

# 只截 Flutter 子窗口的客户区：不带窗口边框，也不会把背后的终端截进来。
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
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
  $previousRoute = $env:TINGYU_DEBUG_ROUTE
  $previousSources = $env:TINGYU_DEBUG_SOURCES
  $previousTheme = $env:TINGYU_DEBUG_THEME
  $previousDensity = $env:TINGYU_DEBUG_DENSITY
  if ($Theme -ne 'system') { $env:TINGYU_DEBUG_THEME = $Theme } else { $env:TINGYU_DEBUG_THEME = $null }
  if ($Density -ne 'comfortable') { $env:TINGYU_DEBUG_DENSITY = $Density } else { $env:TINGYU_DEBUG_DENSITY = $null }
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
      [void][TingyuShotNative]::SetWindowPos($window, [IntPtr](-1), 0, 0, $Width, $Height, 0x0040)
      [void][TingyuShotNative]::SetForegroundWindow($window)
      Start-Sleep -Seconds 4
      $child = [TingyuShotNative]::GetWindow($window, 5)
      if ($child -eq [IntPtr]::Zero) { throw "Flutter 子窗口未找到（$route）" }
      $scale = [TingyuShotNative]::GetDpiForWindow($child) / 96.0
      $client = [TingyuShotNative+Rect]::new()
      [void][TingyuShotNative]::GetClientRect($child, [ref]$client)
      Write-Host ("截图 $route → $name.png：$($client.Right)x$($client.Bottom) 物理像素，DPI 缩放 $scale")
      Save-ClientShot $child (Join-Path $OutputDirectory "$name.png")
    } finally {
      if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    }
  }
} finally {
  $env:TINGYU_DEBUG_ROUTE = $previousRoute
  $env:TINGYU_DEBUG_SOURCES = $previousSources
  $env:TINGYU_DEBUG_THEME = $previousTheme
  $env:TINGYU_DEBUG_DENSITY = $previousDensity
}
