param([string]$Checkout = (Join-Path $PSScriptRoot '../app/build/flutter-engine/checkout'))
$ErrorActionPreference = 'Stop'
$Checkout = [IO.Path]::GetFullPath($Checkout)
# Finish checkouts left without HEAD by interrupted initial gclient fetches.
# Only use revisions explicitly pinned in this checkout's DEPS file.
$deps = Get-Content (Join-Path $Checkout 'DEPS') -Raw
$matches = [regex]::Matches($deps, "'(?<path>engine/src/[^']+)':\s*Var\('[^']+'\)[^\r\n]*'@'\s*\+\s*'(?<revision>[0-9a-f]{40})'")
foreach ($entry in $matches) {
  $directory = Join-Path $Checkout $entry.Groups['path'].Value
  if (!(Test-Path -LiteralPath (Join-Path $directory '.git'))) { continue }
  $ErrorActionPreference = 'Continue'
  & git -C $directory rev-parse --verify HEAD 2>$null | Out-Null
  $hasHead = $LASTEXITCODE -eq 0
  $ErrorActionPreference = 'Stop'
  if ($hasHead) { continue }
  $revision = $entry.Groups['revision'].Value
  Write-Output "Completing pinned dependency: $($entry.Groups['path'].Value)"
  & git -C $directory fetch --depth 1 origin $revision
  if ($LASTEXITCODE -ne 0) { throw "Fetch failed: $directory" }
  & git -C $directory checkout --detach $revision
  if ($LASTEXITCODE -ne 0) { throw "Checkout failed: $directory" }
}
