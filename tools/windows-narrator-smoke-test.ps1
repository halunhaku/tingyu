param([Parameter(Mandatory=$true)][string]$AppDirectory,
      [Parameter(Mandatory=$true)][string]$OutputDirectory,
      [int]$LibraryRow = 2,
      [int]$Cycles = 30)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class TingyuNarratorControl {
  [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, System.UIntPtr extra);
  public static void Toggle() {
    keybd_event(0x5B,0,0,System.UIntPtr.Zero);
    keybd_event(0x11,0,0,System.UIntPtr.Zero);
    keybd_event(0x0D,0,0,System.UIntPtr.Zero);
    keybd_event(0x0D,0,2,System.UIntPtr.Zero);
    keybd_event(0x11,0,2,System.UIntPtr.Zero);
    keybd_event(0x5B,0,2,System.UIntPtr.Zero);
  }
}
'@
$existingNarrators = @(Get-Process Narrator -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$ownedNarrators = @()
$record = [ordered]@{ startedAt=(Get-Date).ToString('o'); existingProcessIds=$existingNarrators }
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
try {
  if ($existingNarrators.Count -eq 0) {
    Start-Process -FilePath "$env:WINDIR/System32/Narrator.exe" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $ownedNarrators = @(Get-Process Narrator -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  }
  $record.processIdsBefore = @(Get-Process Narrator -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  if ($record.processIdsBefore.Count -eq 0) { throw 'Narrator did not start' }
  & (Join-Path $PSScriptRoot 'windows-smoke-test.ps1') -AppDirectory $AppDirectory -OutputDirectory $OutputDirectory -LibraryTrack -LibraryRow $LibraryRow -Cycles $Cycles -EnableAccessibility
  $record.processIdsAfter = @(Get-Process Narrator -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  if ($record.processIdsAfter.Count -eq 0) { throw 'Narrator exited before smoke test finished' }
  $record.passed = $true
} finally {
  $record.finishedAt = (Get-Date).ToString('o')
  $record | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'narrator-session.json')
  $remainingOwned = @($ownedNarrators | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Where-Object { $_.ProcessName -eq 'Narrator' })
  if ($remainingOwned.Count -gt 0) {
    # Narrator uses UIAccess; its Path may be unavailable to a normal process.
    # Use Windows' supported shortcut to stop only a session started above.
    [TingyuNarratorControl]::Toggle()
    Start-Sleep -Seconds 2
  }
}
