param(
  [Parameter(Mandatory=$true)][string]$AppDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [int]$Width = 2160,
  [int]$Height = 1350,
  # 逻辑坐标（×1.5 DPI 后就是客户区物理坐标）：'名称:x,y'，按顺序点击并截图。
  [string[]]$Steps = @('01-add-source-dialog:1331,49')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TingyuFlowNative {
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
  public struct Rect { public int Left, Top, Right, Bottom; }
  public struct Point { public int X, Y; }
}
'@
[void][TingyuFlowNative]::SetThreadDpiAwarenessContext([IntPtr](-4))

function Save-ClientShot($child, $path) {
  $rect = [TingyuFlowNative+Rect]::new()
  [void][TingyuFlowNative]::GetClientRect($child, [ref]$rect)
  $origin = [TingyuFlowNative+Point]::new()
  [void][TingyuFlowNative]::ClientToScreen($child, [ref]$origin)
  $bitmap = [Drawing.Bitmap]::new($rect.Right, $rect.Bottom)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size)
    $bitmap.Save($path)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Click-Client($child, [int]$x, [int]$y) {
  $point = [TingyuFlowNative+Point]::new()
  $point.X = $x; $point.Y = $y
  [void][TingyuFlowNative]::ClientToScreen($child, [ref]$point)
  [void][TingyuFlowNative]::SetCursorPos($point.X, $point.Y)
  [TingyuFlowNative]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [TingyuFlowNative]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

$env:TINGYU_DEBUG_ROUTE = '/sources'
$env:TINGYU_DEBUG_SOURCES = $null
$process = Start-Process -FilePath (Join-Path $AppDirectory 'tingyu.exe') -WorkingDirectory $AppDirectory -PassThru
try {
  Start-Sleep -Seconds 7
  $process.Refresh()
  if ($process.HasExited) { throw "启动失败：$($process.ExitCode)" }
  $window = $process.MainWindowHandle
  [void][TingyuFlowNative]::SetWindowPos($window, [IntPtr](-1), 0, 0, $Width, $Height, 0x0040)
  [void][TingyuFlowNative]::SetForegroundWindow($window)
  Start-Sleep -Seconds 4
  $child = [TingyuFlowNative]::GetWindow($window, 5)
  if ($child -eq [IntPtr]::Zero) { throw 'Flutter 子窗口未找到' }
  $scale = [TingyuFlowNative]::GetDpiForWindow($child) / 96.0

  foreach ($step in $Steps) {
    $parts = $step.Split(':')
    $name = $parts[0]
    $coords = $parts[1].Split(',')
    Click-Client $child ([int]([double]$coords[0] * $scale)) ([int]([double]$coords[1] * $scale))
    Start-Sleep -Seconds 3
    Save-ClientShot $child (Join-Path $OutputDirectory "$name.png")
    Write-Host "shot $name at $($coords[0]),$($coords[1])"
  }
} finally {
  if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
  $env:TINGYU_DEBUG_ROUTE = $null
}
