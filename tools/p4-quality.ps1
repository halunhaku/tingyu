param(
  [ValidateSet('all','static','widget','golden','visual','runtime')]
  [string]$Stage = 'all',
  [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
  [string]$EvidenceDirectory = 'docs/ui-redesign/p4-evidence',
  [int]$SmokeCycles = 10
)
$ErrorActionPreference = 'Stop'

$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$app = Join-Path $repository 'app'
$evidence = [IO.Path]::GetFullPath((Join-Path $repository $EvidenceDirectory))
$gateDirectory = Join-Path $evidence 'gates'
$runtimeVisualDirectory = Join-Path $evidence 'runtime-visual'
$productionEvidence = Join-Path $evidence 'production-smoke'
$sealPath = Join-Path $repository 'docs/ui-redesign/p4-quality/approved-visual-assets.sha256'
$casesPath = Join-Path $repository 'docs/ui-redesign/p4-quality/runtime-visual-cases.json'
$pwsh = (Get-Process -Id $PID).Path
New-Item -ItemType Directory -Force -Path $gateDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $productionEvidence | Out-Null

$startedAt = Get-Date
$records = [Collections.Generic.List[object]]::new()
$script:failed = $false

function Get-CommandDisplay([string]$filePath, [string[]]$arguments) {
  return (@($filePath) + $arguments | ForEach-Object { [string]$_ }) -join ' '
}

function Invoke-GateCommand {
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][string]$DisplayName,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments = @()
  )
  $logPath = Join-Path $gateDirectory "$Id.txt"
  $started = Get-Date
  $exitCode = 0
  try {
    Push-Location $WorkingDirectory
    try {
      & $FilePath @Arguments *> $logPath
      $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } finally {
      Pop-Location
    }
  } catch {
    $exitCode = 127
    $_ | Out-String | Add-Content -Encoding UTF8 $logPath
  }
  $record = [ordered]@{
    id = $Id
    displayName = $DisplayName
    command = Get-CommandDisplay $FilePath $Arguments
    workingDirectory = $WorkingDirectory
    startedAt = $started.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    exitCode = $exitCode
    passed = $exitCode -eq 0
    log = [IO.Path]::GetRelativePath($evidence, $logPath).Replace('\', '/')
  }
  $records.Add($record)
  Write-Host "[$Id] exit=$exitCode log=$logPath"
  return $exitCode -eq 0
}

function Test-VisualSeal {
  $logPath = Join-Path $gateDirectory 'visual-asset-seal.txt'
  $started = Get-Date
  $failures = [Collections.Generic.List[string]]::new()
  $logLines = [Collections.Generic.List[string]]::new()
  if (!(Test-Path -LiteralPath $sealPath -PathType Leaf)) {
    $failures.Add("Seal not found: $sealPath")
  } else {
    foreach ($line in Get-Content -LiteralPath $sealPath) {
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }
      $match = [regex]::Match($line, '^([0-9a-f]{64})  (.+)$')
      if (!$match.Success) {
        $failures.Add("Malformed seal line: $line")
        continue
      }
      $expected = $match.Groups[1].Value
      $relative = $match.Groups[2].Value.Replace('/', [IO.Path]::DirectorySeparatorChar)
      $absolute = [IO.Path]::GetFullPath((Join-Path $repository $relative))
      if (!(Test-Path -LiteralPath $absolute -PathType Leaf)) {
        $failures.Add("Missing sealed asset: $relative")
        continue
      }
      $actual = (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $expected) {
        $failures.Add("SHA256 mismatch: $relative expected=$expected actual=$actual")
      } else {
        $logLines.Add("$actual  $relative")
      }
    }
  }
  foreach ($failure in $failures) {
    $logLines.Add($failure)
  }
  $logLines | Set-Content -Encoding UTF8 $logPath
  $passed = $failures.Count -eq 0
  $records.Add([ordered]@{
    id = 'visual-asset-seal'
    displayName = 'Approved visual asset SHA256 seal'
    command = "verify $sealPath"
    workingDirectory = $repository
    startedAt = $started.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    exitCode = if ($passed) { 0 } else { 1 }
    passed = $passed
    log = [IO.Path]::GetRelativePath($evidence, $logPath).Replace('\', '/')
  })
  Write-Host "[visual-asset-seal] exit=$(if ($passed) { 0 } else { 1 }) log=$logPath"
  return $passed
}

function Invoke-PreviewBuild {
  $engineSource = Join-Path $app 'build/flutter-engine/checkout/engine/src'
  $manifestPath = Join-Path $repository 'tools/engine-patches/windows-engine.json'
  if (!(Test-Path -LiteralPath $engineSource -PathType Container) -or
      !(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $logPath = Join-Path $gateDirectory 'visual-preview-build.txt'
    "Pinned local engine or manifest is missing.`nengineSource=$engineSource`nmanifest=$manifestPath" |
      Set-Content -Encoding UTF8 $logPath
    $records.Add([ordered]@{
      id = 'visual-preview-build'
      displayName = 'Build fixed-data preview'
      command = 'flutter build windows --release -t tool/voice_archive_preview.dart'
      workingDirectory = $app
      startedAt = (Get-Date).ToString('o')
      finishedAt = (Get-Date).ToString('o')
      exitCode = 1
      passed = $false
      log = [IO.Path]::GetRelativePath($evidence, $logPath).Replace('\', '/')
    })
    return $false
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $arguments = @(
    "--local-engine-src-path=$engineSource"
    "--local-engine=$($manifest.configuration)"
    "--local-engine-host=$($manifest.configuration)"
    'build'
    'windows'
    '--release'
    '-t'
    'tool/voice_archive_preview.dart'
  )
  return Invoke-GateCommand `
    -Id 'visual-preview-build' `
    -DisplayName 'Build fixed-data preview with pinned Windows engine' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments $arguments
}

function Invoke-ProductionBuild {
  return Invoke-GateCommand `
    -Id 'production-build' `
    -DisplayName 'Build production Windows application with pinned engine' `
    -WorkingDirectory $repository `
    -FilePath $pwsh `
    -Arguments @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      (Join-Path $repository 'tools/build-windows-engine.ps1')
      '-Stage'
      'App'
    )
}

function Invoke-ProductionSmoke {
  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $smokeOutput = Join-Path $app "build/p4-production-smoke/$timestamp"
  New-Item -ItemType Directory -Force -Path $smokeOutput | Out-Null
  $appDirectory = Join-Path $app 'build/windows/x64/runner/Release'
  $passed = Invoke-GateCommand `
    -Id 'production-smoke' `
    -DisplayName 'Real local playback and navigation smoke' `
    -WorkingDirectory $repository `
    -FilePath $pwsh `
    -Arguments @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      (Join-Path $repository 'tools/windows-smoke-test.ps1')
      '-AppDirectory'
      $appDirectory
      '-OutputDirectory'
      $smokeOutput
      '-Cycles'
      [string]$SmokeCycles
    )
  foreach ($file in @('result.json', 'stdout.log', 'stderr.log')) {
    $source = Join-Path $smokeOutput $file
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $productionEvidence $file) -Force
    }
  }
  return $passed
}

function Run-StaticStage {
  $formatPassed = Invoke-GateCommand `
    -Id 'format' `
    -DisplayName 'Format check for P4 Dart changes' `
    -WorkingDirectory $app `
    -FilePath 'dart' `
    -Arguments @(
      'format'
      '--output=none'
      '--set-exit-if-changed'
      'lib/data/secure_store.dart'
    )
  if (!$formatPassed) {
    return $false
  }
  $analyzePassed = Invoke-GateCommand `
    -Id 'analyze' `
    -DisplayName 'Flutter static analysis' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments @('analyze')
  if (!$analyzePassed) {
    return $false
  }
  return Invoke-GateCommand `
    -Id 'non-golden-tests' `
    -DisplayName 'All non-Golden Dart and Flutter tests' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments @('test', '--exclude-tags', 'golden')
}

function Run-WidgetStage {
  $tests = @(
    'test/design_guard_test.dart'
    'test/form_factor_test.dart'
    'test/async_state_test.dart'
    'test/now_playing_layout_test.dart'
    'test/transport_row_layout_test.dart'
    'test/library_page_redesign_test.dart'
    'test/sources_page_redesign_test.dart'
    'test/search_page_test.dart'
    'test/navigation_gesture_test.dart'
    'test/ui_rebuild_seek_test.dart'
    'test/performance_regression_test.dart'
    'test/quark_login_render_test.dart'
  )
  foreach ($test in $tests) {
    if (!(Test-Path -LiteralPath (Join-Path $app $test) -PathType Leaf)) {
      throw "Critical interaction test not found: $test"
    }
  }
  return Invoke-GateCommand `
    -Id 'widget-interactions' `
    -DisplayName 'Critical widget and interaction tests' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments (@('test') + $tests)
}

function Run-GoldenStage {
  return Invoke-GateCommand `
    -Id 'golden' `
    -DisplayName 'Verify all approved Golden images without updating them' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments @(
      'test'
      '--run-skipped'
      '-t'
      'golden'
      'test/golden/core_pages_golden_test.dart'
    )
}

function Run-VisualStage {
  if (!(Invoke-PreviewBuild)) {
    return $false
  }
  return Invoke-GateCommand `
    -Id 'runtime-visual' `
    -DisplayName 'Capture and pixel-compare six approved runtime states' `
    -WorkingDirectory $repository `
    -FilePath $pwsh `
    -Arguments @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      (Join-Path $repository 'tools/p4-runtime-visual.ps1')
      '-RepositoryRoot'
      $repository
      '-CasesFile'
      'docs/ui-redesign/p4-quality/runtime-visual-cases.json'
      '-OutputDirectory'
      'docs/ui-redesign/p4-evidence/runtime-visual'
    )
}

function Run-RuntimeStage {
  if (!(Invoke-ProductionBuild)) {
    return $false
  }
  return Invoke-ProductionSmoke
}

try {
  if (!(Test-VisualSeal)) {
    $script:failed = $true
    throw 'Approved visual asset seal failed.'
  }

  $stages = if ($Stage -eq 'all') {
    @('static', 'widget', 'golden', 'visual', 'runtime')
  } else {
    @($Stage)
  }
  foreach ($currentStage in $stages) {
    $passed = switch ($currentStage) {
      'static' { Run-StaticStage }
      'widget' { Run-WidgetStage }
      'golden' { Run-GoldenStage }
      'visual' { Run-VisualStage }
      'runtime' { Run-RuntimeStage }
      default { throw "Unknown stage: $currentStage" }
    }
    if (!$passed) {
      $script:failed = $true
      break
    }
  }
} catch {
  $script:failed = $true
  $_ | Out-String | Add-Content -Encoding UTF8 (Join-Path $gateDirectory 'orchestrator-error.txt')
} finally {
  $finishedAt = Get-Date
  $branch = (& git -C $repository branch --show-current).Trim()
  $commit = (& git -C $repository rev-parse HEAD).Trim()
  $result = [ordered]@{
    schemaVersion = 1
    requestedStage = $Stage
    startedAt = $startedAt.ToString('o')
    finishedAt = $finishedAt.ToString('o')
    durationSeconds = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
    branch = $branch
    commit = $commit
    passed = !$script:failed -and @($records | Where-Object { !$_.passed }).Count -eq 0
    environment = [ordered]@{
      platform = [Environment]::OSVersion.VersionString
      powershell = $PSVersionTable.PSVersion.ToString()
      flutter = (& flutter --version --machine | ConvertFrom-Json | Select-Object frameworkVersion, frameworkRevision, dartSdkVersion)
    }
    gates = @($records)
    evidence = [ordered]@{
      goldenDirectory = 'app/test/golden/goldens'
      runtimeVisualDirectory = [IO.Path]::GetRelativePath($evidence, $runtimeVisualDirectory).Replace('\', '/')
      productionSmokeDirectory = [IO.Path]::GetRelativePath($evidence, $productionEvidence).Replace('\', '/')
      approvedVisualSeal = 'docs/ui-redesign/p4-quality/approved-visual-assets.sha256'
    }
    limitations = @(
      'Only Windows runtime visual and production smoke gates were executed locally.'
      'CI build success for Android, iOS, macOS and Linux does not prove their runtime interaction or visual quality.'
      'No real Quark/WebDAV credentials or remote playback were used.'
      'No manual screen-reader review is represented by these automated gates.'
    )
  }
  $result | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (
    Join-Path $evidence 'quality-gates-results.json'
  )
}

if ($script:failed) {
  exit 1
}
exit 0
