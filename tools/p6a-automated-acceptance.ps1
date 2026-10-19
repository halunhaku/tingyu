param(
  [ValidateSet(
    'all',
    'static',
    'interaction',
    'integration',
    'regression',
    'golden',
    'visual',
    'runtime'
  )]
  [string]$Stage = 'all',
  [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
  [string]$EvidenceDirectory = 'docs/ui-redesign/p6a-evidence',
  [int]$SmokeCycles = 10,
  [int]$VisualWaitSeconds = 5
)
$ErrorActionPreference = 'Stop'

$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$app = Join-Path $repository 'app'
$evidence = [IO.Path]::GetFullPath((Join-Path $repository $EvidenceDirectory))
$gateDirectory = Join-Path $evidence 'gates'
$approvedRuntimeDirectory = Join-Path $evidence 'approved-runtime'
$matrixDirectory = Join-Path $evidence 'runtime-matrix'
$productionSmokeDirectory = Join-Path $evidence 'production-smoke'
$sealPath = Join-Path $repository 'docs/ui-redesign/p4-quality/approved-visual-assets.sha256'
$pwsh = (Get-Process -Id $PID).Path
New-Item -ItemType Directory -Force -Path $gateDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $productionSmokeDirectory | Out-Null

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

function Test-ApprovedVisualSeal {
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
    displayName = 'Approved Golden and P4 runtime baseline SHA256 seal'
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
      displayName = 'Build fixed-data preview with pinned Windows engine'
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
  return Invoke-GateCommand `
    -Id 'visual-preview-build' `
    -DisplayName 'Build fixed-data preview with pinned Windows engine' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments @(
      "--local-engine-src-path=$engineSource"
      "--local-engine=$($manifest.configuration)"
      "--local-engine-host=$($manifest.configuration)"
      'build'
      'windows'
      '--release'
      '-t'
      'tool/voice_archive_preview.dart'
    )
}

function Run-StaticStage {
  $formatPassed = Invoke-GateCommand `
    -Id 'format' `
    -DisplayName 'Format check for P6A Dart changes' `
    -WorkingDirectory $app `
    -FilePath 'dart' `
    -Arguments @(
      'format'
      '--output=none'
      '--set-exit-if-changed'
      'lib/design/components/interactive.dart'
      'lib/sources/quark/quark_drive_client.dart'
      'test/p6a_interaction_contract_test.dart'
      'test/webdav_http_integration_test.dart'
      'test/quark_http_fixture_test.dart'
    )
  if (!$formatPassed) {
    return $false
  }
  return Invoke-GateCommand `
    -Id 'analyze' `
    -DisplayName 'Flutter static analysis' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments @('analyze')
}

function Run-InteractionStage {
  $tests = @(
    'test/p6a_interaction_contract_test.dart'
    'test/p5_review_regression_test.dart'
    'test/design_system_render_test.dart'
    'test/form_factor_test.dart'
    'test/library_page_redesign_test.dart'
    'test/sources_page_redesign_test.dart'
    'test/voice_archive_stage_layout_test.dart'
    'test/now_playing_layout_test.dart'
    'test/navigation_gesture_test.dart'
  )
  foreach ($test in $tests) {
    if (!(Test-Path -LiteralPath (Join-Path $app $test) -PathType Leaf)) {
      throw "Interaction test not found: $test"
    }
  }
  return Invoke-GateCommand `
    -Id 'interaction-contracts' `
    -DisplayName 'Keyboard, overlay, semantics and responsive interaction contracts' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments (@('test') + $tests)
}

function Run-IntegrationStage {
  $tests = @(
    'test/webdav_http_integration_test.dart'
    'test/quark_http_fixture_test.dart'
    'test/webdav_test.dart'
    'test/quark_test.dart'
    'test/source_sync_test.dart'
    'test/database_migration_test.dart'
  )
  foreach ($test in $tests) {
    if (!(Test-Path -LiteralPath (Join-Path $app $test) -PathType Leaf)) {
      throw "Integration test not found: $test"
    }
  }
  return Invoke-GateCommand `
    -Id 'local-integrations' `
    -DisplayName 'Loopback HTTP protocol fixtures and database migration tests' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments (@('test') + $tests)
}

function Run-RegressionStage {
  return Invoke-GateCommand `
    -Id 'non-golden-tests' `
    -DisplayName 'All non-Golden unit, widget and integration tests' `
    -WorkingDirectory $app `
    -FilePath 'flutter' `
    -Arguments @('test', '--exclude-tags', 'golden')
}

function Run-GoldenStage {
  return Invoke-GateCommand `
    -Id 'golden' `
    -DisplayName 'Verify approved Golden images without updating them' `
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
  $approvedPassed = Invoke-GateCommand `
    -Id 'approved-runtime-visual' `
    -DisplayName 'Compare six approved runtime states without updating baselines' `
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
      ([IO.Path]::GetRelativePath($repository, $approvedRuntimeDirectory).Replace('\', '/'))
      '-WaitSeconds'
      [string]$VisualWaitSeconds
    )
  if (!$approvedPassed) {
    return $false
  }
  return Invoke-GateCommand `
    -Id 'response-runtime-matrix' `
    -DisplayName 'Capture P6A diagnostic responsive and large-text matrix' `
    -WorkingDirectory $repository `
    -FilePath $pwsh `
    -Arguments @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      (Join-Path $repository 'tools/p6a-runtime-matrix.ps1')
      '-RepositoryRoot'
      $repository
      '-OutputDirectory'
      ([IO.Path]::GetRelativePath($repository, $matrixDirectory).Replace('\', '/'))
      '-WaitSeconds'
      [string]$VisualWaitSeconds
    )
}

function Run-RuntimeStage {
  $buildPassed = Invoke-GateCommand `
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
  if (!$buildPassed) {
    return $false
  }
  return Invoke-GateCommand `
    -Id 'production-smoke' `
    -DisplayName 'Real local WAV playback, navigation and automated accessibility tree' `
    -WorkingDirectory $repository `
    -FilePath $pwsh `
    -Arguments @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      (Join-Path $repository 'tools/windows-smoke-test.ps1')
      '-AppDirectory'
      (Join-Path $app 'build/windows/x64/runner/Release')
      '-OutputDirectory'
      $productionSmokeDirectory
      '-Cycles'
      [string]$SmokeCycles
      '-EnableAccessibility'
    )
}

try {
  if (!(Test-ApprovedVisualSeal)) {
    $script:failed = $true
    throw 'Approved visual asset seal failed.'
  }

  $stages = if ($Stage -eq 'all') {
    @('static', 'interaction', 'integration', 'regression', 'golden', 'visual', 'runtime')
  } else {
    @($Stage)
  }
  foreach ($currentStage in $stages) {
    $passed = switch ($currentStage) {
      'static' { Run-StaticStage }
      'interaction' { Run-InteractionStage }
      'integration' { Run-IntegrationStage }
      'regression' { Run-RegressionStage }
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
      approvedRuntimeVisualDirectory = [IO.Path]::GetRelativePath($evidence, $approvedRuntimeDirectory).Replace('\', '/')
      responseMatrixDirectory = [IO.Path]::GetRelativePath($evidence, $matrixDirectory).Replace('\', '/')
      productionSmokeDirectory = [IO.Path]::GetRelativePath($evidence, $productionSmokeDirectory).Replace('\', '/')
      approvedVisualSeal = 'docs/ui-redesign/p4-quality/approved-visual-assets.sha256'
    }
    limitations = @(
      'P6A runs on Windows only and uses fixed local fixtures for source protocols.'
      'The loopback WebDAV and Quark servers prove transport and protocol contracts, not a real remote account.'
      'The diagnostic response matrix has no approved pixel baseline; it does not certify visual quality.'
      'Android, iOS, macOS and Linux runtime rendering, real-device touch, system text scaling and manual screen readers remain P6B work.'
    )
  }
  $result | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 (
    Join-Path $evidence 'automated-acceptance-results.json'
  )
}

if ($script:failed) {
  exit 1
}
exit 0
