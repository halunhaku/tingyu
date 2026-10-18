param(
  [Parameter(Mandatory=$true)][string]$AppDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [switch]$LibraryTrack,
  [switch]$EnableAccessibility,
  [ValidateRange(1,8)][int]$LibraryRow = 1,
  [int]$Cycles = 10
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TingyuSmokeNative {
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
  public struct Point { public int X, Y; }
  public struct Rect { public int Left, Top, Right, Bottom; }
}
'@
[void][TingyuSmokeNative]::SetThreadDpiAwarenessContext([IntPtr](-4))

# A local 120-second tone keeps network and expiring URLs out of this smoke test.
$tone = Join-Path $OutputDirectory 'smoke-tone.wav'
$writer = [IO.BinaryWriter]::new([IO.File]::Create($tone))
try {
  $sampleRate = 16000
  $samples = $sampleRate * 120
  $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
  $writer.Write([int](36 + $samples * 2))
  $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
  $writer.Write([int]16)
  $writer.Write([int16]1); $writer.Write([int16]1)
  $writer.Write([int]$sampleRate); $writer.Write([int]($sampleRate * 2))
  $writer.Write([int16]2); $writer.Write([int16]16)
  $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
  $writer.Write([int]($samples * 2))
  for ($i = 0; $i -lt $samples; $i++) {
    $writer.Write([int16](500 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $sampleRate)))
  }
} finally { $writer.Dispose() }

function Save-Screenshot($window, $name) {
  $rect = [TingyuSmokeNative+Rect]::new()
  [void][TingyuSmokeNative]::GetWindowRect($window, [ref]$rect)
  $bitmap = [Drawing.Bitmap]::new($rect.Right-$rect.Left, $rect.Bottom-$rect.Top)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
    $bitmap.Save((Join-Path $OutputDirectory $name))
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Click-Client($window, [int]$x, [int]$y) {
  $point = [TingyuSmokeNative+Point]::new()
  $point.X=$x; $point.Y=$y
  [void][TingyuSmokeNative]::ClientToScreen($window,[ref]$point)
  [void][TingyuSmokeNative]::SetCursorPos($point.X,$point.Y)
  [TingyuSmokeNative]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 20
  [TingyuSmokeNative]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
function Get-LatestPlaybackSnapshot {
  $line = Get-Content (Join-Path $OutputDirectory 'stdout.log') -Tail 100 |
    Where-Object { $_ -match '\[snapshot\].*processing=ready playing=true' } |
    Select-Object -Last 1
  if ([string]::IsNullOrWhiteSpace($line) -or
      $line -notmatch 'processing=ready playing=true position=(\d+)ms duration=(\d+)ms index=(-?\d+)') {
    return $null
  }
  return [pscustomobject]@{
    Line = [string]$line
    PositionMs = [long]$Matches[1]
    DurationMs = [long]$Matches[2]
    Index = [int]$Matches[3]
  }
}
function Wait-ForPlaying([int]$TimeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
    if ($process.HasExited) { throw 'Application exited before playback became ready' }
    $snapshot = Get-LatestPlaybackSnapshot
    if ($null -ne $snapshot) { return $snapshot }
  } while ((Get-Date) -lt $deadline)
  throw "Playback did not reach processing=ready playing=true within $TimeoutSeconds seconds"
}
$previousSource = $env:TINGYU_DEBUG_SOURCES
$previousPlaybackLog = $env:TINGYU_DEBUG_PLAYBACK_LOG
$previousAccessibility = $env:TINGYU_WINDOWS_ACCESSIBILITY
$process = $null
try {
  $env:TINGYU_DEBUG_SOURCES = if ($LibraryTrack) { '' } else { $tone }
  $env:TINGYU_DEBUG_PLAYBACK_LOG = '1'
  if ($EnableAccessibility) { $env:TINGYU_WINDOWS_ACCESSIBILITY = '1' }
  $process = Start-Process -FilePath (Join-Path $AppDirectory 'tingyu.exe') -WorkingDirectory $AppDirectory -PassThru -RedirectStandardOutput (Join-Path $OutputDirectory 'stdout.log') -RedirectStandardError (Join-Path $OutputDirectory 'stderr.log')
} finally {
  $env:TINGYU_DEBUG_SOURCES = $previousSource
  $env:TINGYU_DEBUG_PLAYBACK_LOG = $previousPlaybackLog
  $env:TINGYU_WINDOWS_ACCESSIBILITY = $previousAccessibility
}
try {
  Start-Sleep -Seconds 8
  $process.Refresh()
  if ($process.HasExited) { throw "Startup failed: $($process.ExitCode)" }
  $window = $process.MainWindowHandle
  [void][TingyuSmokeNative]::SetWindowPos($window,[IntPtr](-1),0,0,1200,900,0x0040)
  [void][TingyuSmokeNative]::SetForegroundWindow($window)
  Start-Sleep -Seconds 1
  $child = [TingyuSmokeNative]::GetWindow($window,5)
  if ($child -eq [IntPtr]::Zero) { throw 'Flutter child window not found' }
  $rect = [TingyuSmokeNative+Rect]::new()
  [void][TingyuSmokeNative]::GetClientRect($child,[ref]$rect)
  $scale = [TingyuSmokeNative]::GetDpiForWindow($child)/96.0
  Save-Screenshot $window '01-playing.png'
  # Querying UI Automation activates the native accessibility bridge under test.
  $root = [Windows.Automation.AutomationElement]::FromHandle($window)
  $elements = $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
  $elements | ForEach-Object { $_.Current.Name } | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'accessibility-before.txt')
  if ($LibraryTrack) {
    # Real library row, through PlaybackController and its remote URI resolver.
    Click-Client $child ([int](400*$scale)) ([int]((80+52*($LibraryRow-1))*$scale))
  }
  $playbackStart = Wait-ForPlaying 30
  for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $process.Refresh()
    if ($process.HasExited) { break }
    Click-Client $child ($rect.Right-[int](48*$scale)) ($rect.Bottom-[int](44*$scale))
    Start-Sleep -Milliseconds 180
    if ($cycle -eq 1) { Save-Screenshot $window '02-expanded.png' }
    Click-Client $child ([int](295*$scale)) ([int](28*$scale))
    Start-Sleep -Milliseconds 550
  }
  Start-Sleep -Seconds 3
  $process.Refresh()
  $playbackEnd = Get-LatestPlaybackSnapshot
  $positionDeltaMs = if ($null -ne $playbackEnd) {
    $playbackEnd.PositionMs - $playbackStart.PositionMs
  } else {
    $null
  }
  $result = [ordered]@{
    processId=$process.Id
    libraryTrack=[bool]$LibraryTrack
    accessibilityEnabled=[bool]$EnableAccessibility
    cyclesAttempted=[Math]::Min($cycle-1,$Cycles)
    playbackStart=$playbackStart
    playbackEnd=$playbackEnd
    positionDeltaMs=$positionDeltaMs
    exited=$process.HasExited
    checkedAt=(Get-Date).ToString('o')
  }
  if ($process.HasExited) { $result.exitCode=$process.ExitCode }
  else {
    Save-Screenshot $window '03-after-navigation.png'
    [void][TingyuSmokeNative]::SetWindowPos($window,[IntPtr](-2),0,0,0,0,0x0003)
    $elements = $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    $elements | ForEach-Object { $_.Current.Name } | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'accessibility-after.txt')
    $result.namedAccessibilityElements = @($elements | Where-Object { ![string]::IsNullOrWhiteSpace($_.Current.Name) }).Count
  }
  $result.nativeAccessibilityErrors = @(Get-Content (Join-Path $OutputDirectory 'stderr.log') | Where-Object { $_ -match 'Failed to update ui::AXTree' }).Count
  if ($EnableAccessibility -and !$process.HasExited) {
    & (Join-Path $PSScriptRoot 'windows-accessibility-probe.ps1') -AppProcessId $process.Id -OutputDirectory $OutputDirectory
    $result.msaa = Get-Content (Join-Path $OutputDirectory 'msaa-result.json') -Raw | ConvertFrom-Json
  }
  $result.latestPlaybackSnapshots = @(Get-Content (Join-Path $OutputDirectory 'stdout.log') -Tail 5 | Where-Object { $_ -match 'processing=' } | ForEach-Object { [string]$_ })
  $result | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'result.json')
  $result | ConvertTo-Json
  if ($process.HasExited) { throw 'Navigation regression: application exited' }
  if ($null -eq $playbackEnd -or $positionDeltaMs -le 0) {
    throw 'Playback regression: position did not advance during the smoke test'
  }
  if ($EnableAccessibility -and $result.nativeAccessibilityErrors -gt 0) { throw 'Accessibility regression: native tree update failed' }
  if ($EnableAccessibility -and $result.msaa.namedNodes -lt 4) { throw 'Accessibility regression: application controls were not exposed to MSAA' }
} finally {
  if ($null -ne $process) {
    $process.Refresh()
    if (!$process.HasExited) {
      $process.Kill()
      $process.WaitForExit()
    }
  }
}
