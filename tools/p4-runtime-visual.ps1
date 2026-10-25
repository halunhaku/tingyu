param(
  [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
  [string]$AppDirectory,
  [string]$CasesFile = 'docs/ui-redesign/p4-quality/runtime-visual-cases.json',
  [string]$OutputDirectory = 'docs/ui-redesign/p4-evidence/runtime-visual',
  [int]$WaitSeconds = 8
)
$ErrorActionPreference = 'Stop'

$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$casesPath = [IO.Path]::GetFullPath((Join-Path $repository $CasesFile))
$output = [IO.Path]::GetFullPath((Join-Path $repository $OutputDirectory))
$app = if ([string]::IsNullOrWhiteSpace($AppDirectory)) {
  Join-Path $repository 'app/build/windows/x64/runner/Release'
} else {
  [IO.Path]::GetFullPath($AppDirectory)
}
$screenshots = Join-Path $PSScriptRoot 'windows-ui-screenshots.ps1'
$comparer = Join-Path $PSScriptRoot 'compare-png.ps1'
$pwsh = (Get-Process -Id $PID).Path

function Resolve-RepositoryPath([string]$relativePath) {
  return [IO.Path]::GetFullPath((Join-Path $repository $relativePath))
}

function Assert-FileHash([string]$path, [string]$expected, [string]$label) {
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "$label not found: $path"
  }
  $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected.ToLowerInvariant()) {
    throw "$label checksum mismatch: expected $expected, got $actual"
  }
  return $actual
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw 'Runtime visual gate requires Windows because the approved baselines use Windows DPI and font rasterization.'
}
if (!(Test-Path -LiteralPath $casesPath -PathType Leaf)) {
  throw "Runtime visual case manifest not found: $casesPath"
}
if (!(Test-Path -LiteralPath (Join-Path $app 'tingyu.exe') -PathType Leaf)) {
  throw "Built Flutter preview executable not found: $(Join-Path $app 'tingyu.exe')"
}
New-Item -ItemType Directory -Force -Path $output | Out-Null

$config = Get-Content -LiteralPath $casesPath -Raw | ConvertFrom-Json
$required = $config.requiredEnvironment
if ($required.platform -ne 'windows') {
  throw "Unsupported required platform in case manifest: $($required.platform)"
}
if ([string]::IsNullOrWhiteSpace($config.runtimeBaselineProvenance)) {
  throw 'Runtime baseline provenance manifest is not configured.'
}
$provenancePath = Resolve-RepositoryPath $config.runtimeBaselineProvenance
if (!(Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
  throw "Runtime baseline provenance manifest not found: $provenancePath"
}
$provenanceSha256 = (
  Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256
).Hash.ToLowerInvariant()
$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
if ($provenance.designApprovalBaselineCommit -ne $config.approvedBaselineCommit) {
  throw 'Runtime baseline provenance approval commit does not match the case manifest.'
}
$provenanceById = @{}
foreach ($baseline in @($provenance.baselines)) {
  $provenanceById[$baseline.id] = $baseline
}
if ($provenanceById.Count -ne @($config.cases).Count) {
  throw 'Runtime baseline provenance entry count does not match the case count.'
}

$fixturePath = Resolve-RepositoryPath $config.fixture
if (!(Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
  throw "Preview fixture not found: $fixturePath"
}
$fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
$coverPath = Resolve-RepositoryPath $config.fixtureCover
$coverHash = Assert-FileHash $coverPath $required.fixtureCoverSha256 'Fixture cover'
$fontReadings = @()
foreach ($font in @($required.fonts)) {
  $fontReadings += [ordered]@{
    path = $font.path
    sha256 = Assert-FileHash $font.path $font.sha256 'Required font'
  }
}

$flutterMachine = (& flutter --version --machine | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) {
  throw 'flutter --version --machine failed.'
}
$flutterIdentity = [ordered]@{
  frameworkVersion = $flutterMachine.frameworkVersion
  frameworkRevision = $flutterMachine.frameworkRevision
  dartSdkVersion = $flutterMachine.dartSdkVersion
}
foreach ($property in @('frameworkVersion', 'frameworkRevision', 'dartSdkVersion')) {
  $expected = $required.flutter.$property
  if ($flutterIdentity[$property] -ne $expected) {
    throw "Flutter identity mismatch for ${property}: expected $expected, got $($flutterIdentity[$property])"
  }
}

$gitCommit = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
  throw 'Could not read the current Git commit.'
}

$caseResults = [Collections.Generic.List[object]]::new()
$overallPassed = $true
foreach ($case in @($config.cases)) {
  $provenanceEntry = $provenanceById[$case.id]
  if ($null -eq $provenanceEntry) {
    throw "Runtime baseline provenance entry missing for $($case.id)."
  }
  if ($provenanceEntry.p4Reference -ne $case.approvedReference -or
      $provenanceEntry.p4Sha256 -ne $case.approvedSha256) {
    throw "Runtime baseline provenance does not match approved reference for $($case.id)."
  }
  if ([string]::IsNullOrWhiteSpace($case.sourceReference) -or
      [string]::IsNullOrWhiteSpace($case.sourceSha256)) {
    throw "P3 source reference is incomplete for $($case.id)."
  }
  $sourcePath = Resolve-RepositoryPath $case.sourceReference
  [void](Assert-FileHash $sourcePath $case.sourceSha256 "P3 source reference $($case.id)")
  if ($provenanceEntry.p3SourceReference -ne $case.sourceReference -or
      $provenanceEntry.p3SourceSha256 -ne $case.sourceSha256) {
    throw "P3 source provenance does not match case manifest for $($case.id)."
  }
  $caseDirectory = Join-Path $output $case.id
  New-Item -ItemType Directory -Force -Path $caseDirectory | Out-Null
  $captureLog = Join-Path $caseDirectory 'capture.log'
  $compareLog = Join-Path $caseDirectory 'compare.log'
  $comparisonJson = Join-Path $caseDirectory 'comparison.json'
  $diffPath = Join-Path $caseDirectory 'baseline.diff.png'
  $approvedPath = Resolve-RepositoryPath $case.approvedReference

  try {
    [void](Assert-FileHash $approvedPath $case.approvedSha256 "Approved reference $($case.id)")
    $captureArguments = @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      $screenshots
      '-AppDirectory'
      $app
      '-OutputDirectory'
      $caseDirectory
      '-Routes'
      $case.route
      '-ClientWidth'
      [string]$case.clientWidth
      '-ClientHeight'
      [string]$case.clientHeight
      '-ExpectedDpiScale'
      [string]$required.dpiScale
      '-WaitSeconds'
      [string]$WaitSeconds
      '-Theme'
      $case.theme
      '-PreviewState'
      $case.previewState
      '-PreviewScale'
      [string]$case.previewScale
      '-PreviewCover'
      $case.cover
    )
    $captureOutput = & $pwsh @captureArguments 2>&1
    $captureOutput | Set-Content -Encoding UTF8 $captureLog
    if ($LASTEXITCODE -ne 0) {
      throw "Runtime capture failed; see $captureLog"
    }

    $captureMetadataPath = Join-Path $caseDirectory 'capture-metadata.json'
    $captureMetadata = Get-Content -LiteralPath $captureMetadataPath -Raw | ConvertFrom-Json
    $capture = @($captureMetadata.captures)[0]
    if ($capture.clientWidth -ne $case.clientWidth -or $capture.clientHeight -ne $case.clientHeight) {
      throw "Client area mismatch: expected $($case.clientWidth)x$($case.clientHeight), got $($capture.clientWidth)x$($capture.clientHeight)"
    }
    if ([Math]::Abs([double]$capture.dpiScale - [double]$required.dpiScale) -gt 0.01) {
      throw "DPI scale mismatch: expected $($required.dpiScale), got $($capture.dpiScale)"
    }
    if ($capture.previewState -ne $case.previewState -or
        [double]$capture.previewScale -ne [double]$case.previewScale -or
        $capture.previewCover -ne $case.cover) {
      throw 'Capture metadata does not match the requested preview state.'
    }

    $actualPath = Join-Path $caseDirectory $case.captureFile
    if (!(Test-Path -LiteralPath $actualPath -PathType Leaf)) {
      throw "Expected runtime screenshot not found: $actualPath"
    }
    $compareArguments = @(
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-File'
      $comparer
      '-ApprovedPath'
      $approvedPath
      '-ActualPath'
      $actualPath
      '-DiffPath'
      $diffPath
      '-OutputJson'
      $comparisonJson
    )
    $compareOutput = @(& $pwsh @compareArguments 2>&1)
    $compareExitCode = $LASTEXITCODE
    $comparison = Get-Content -LiteralPath $comparisonJson -Raw | ConvertFrom-Json
    $compareLogLines = if ($compareOutput.Count -gt 0) {
      $compareOutput
    } else {
      @(
        'Visual comparison passed.'
        "approvedSha256=$($comparison.approvedSha256)"
        "actualSha256=$($comparison.actualSha256)"
        "pixelExact=$($comparison.pixelExact)"
        "byteExact=$($comparison.byteExact)"
        "differingPixels=$($comparison.differingPixels)"
      )
    }
    $compareLogLines | Set-Content -Encoding UTF8 $compareLog
    $casePassed = $compareExitCode -eq 0 -and [bool]$comparison.pixelExact
    if (!$casePassed) {
      $overallPassed = $false
    }
    $caseResults.Add([ordered]@{
      id = $case.id
      route = $case.route
      viewport = [ordered]@{
        width = $case.clientWidth
        height = $case.clientHeight
        dpiScale = $required.dpiScale
      }
      theme = $case.theme
      previewState = $case.previewState
      previewScale = $case.previewScale
      cover = $case.cover
      passed = $casePassed
      approvedReference = $case.approvedReference
      approvedSha256 = $comparison.approvedSha256
      sourceReference = $case.sourceReference
      sourceSha256 = $case.sourceSha256
      actualFile = [IO.Path]::GetRelativePath($output, $actualPath).Replace('\', '/')
      actualSha256 = $comparison.actualSha256
      sameDimensions = $comparison.sameDimensions
      pixelExact = $comparison.pixelExact
      byteExact = $comparison.byteExact
      differingPixels = $comparison.differingPixels
      differingPercent = $comparison.differingPercent
      maxChannelDelta = $comparison.maxChannelDelta
      meanAbsoluteDelta = $comparison.meanAbsoluteDelta
      differenceBounds = $comparison.differenceBounds
      comparison = [IO.Path]::GetRelativePath($output, $comparisonJson).Replace('\', '/')
      diffImage = [IO.Path]::GetRelativePath($output, $diffPath).Replace('\', '/')
      captureLog = [IO.Path]::GetRelativePath($output, $captureLog).Replace('\', '/')
      compareLog = [IO.Path]::GetRelativePath($output, $compareLog).Replace('\', '/')
    })
  } catch {
    $overallPassed = $false
    $caseResults.Add([ordered]@{
      id = $case.id
      route = $case.route
      viewport = [ordered]@{
        width = $case.clientWidth
        height = $case.clientHeight
        dpiScale = $required.dpiScale
      }
      theme = $case.theme
      previewState = $case.previewState
      previewScale = $case.previewScale
      cover = $case.cover
      passed = $false
      error = $_.Exception.Message
      captureLog = [IO.Path]::GetRelativePath($output, $captureLog).Replace('\', '/')
      compareLog = [IO.Path]::GetRelativePath($output, $compareLog).Replace('\', '/')
    })
  }
}

$result = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToString('o')
  approvedBaselineCommit = $config.approvedBaselineCommit
  currentCommit = $gitCommit
  platform = 'Windows'
  fixture = $config.fixture
  fixtureSha256 = $fixtureHash
  fixtureCover = $config.fixtureCover
  fixtureCoverSha256 = $coverHash
  runtimeBaselineProvenance = $config.runtimeBaselineProvenance
  runtimeBaselineProvenanceSha256 = $provenanceSha256
  flutter = $flutterIdentity
  fonts = $fontReadings
  animationsDisabled = [bool]$required.animationsDisabled
  overallPassed = $overallPassed
  cases = @($caseResults)
  limitations = @(
    'Windows fixed preview only; this does not prove Android, iOS, macOS or Linux rendering.'
    'The preview fixture does not exercise real Quark, WebDAV, database or playback-engine behavior.'
    'Pixel equality proves regression against the approved Windows baselines, not general commercial visual quality.'
  )
}
$resultsPath = Join-Path $output 'runtime-visual-results.json'
$result | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $resultsPath

$reviewLines = [Collections.Generic.List[string]]::new()
$reviewLines.Add('# P4 实际运行视觉审查')
$reviewLines.Add('')
$reviewLines.Add("生成时间：$($result.generatedAt)")
$reviewLines.Add('')
$reviewLines.Add(
  '固定数据、Windows DPI 1.5、固定字体、固定客户区、关闭动画；逐像素比较 P4 清洁运行时基准。'
)
$reviewLines.Add('')
$reviewLines.Add('| 用例 | 视口 | 差异像素 | 差异比例 | 结论 |')
$reviewLines.Add('|---|---:|---:|---:|---|')
foreach ($caseResult in @($caseResults)) {
  $differing = if ($null -ne $caseResult.differingPixels) { $caseResult.differingPixels } else { '—' }
  $percent = if ($null -ne $caseResult.differingPercent) {
    ([double]$caseResult.differingPercent).ToString('F6', [Globalization.CultureInfo]::InvariantCulture) + '%'
  } else {
    '—'
  }
  $status = if ($caseResult.passed) { '通过' } else { '失败' }
  $reviewLines.Add(
    "| ``$($caseResult.id)`` | $($caseResult.viewport.width)×$($caseResult.viewport.height) | $differing | $percent | $status |"
  )
}
$reviewLines.Add('')
$issues = @($caseResults | Where-Object { !$_.passed })
if ($issues.Count -eq 0) {
  $reviewLines.Add('## 可执行问题')
  $reviewLines.Add('')
  $reviewLines.Add('没有发现与已批准基准的可执行视觉差异。')
} else {
  $reviewLines.Add('## 可执行问题')
  $reviewLines.Add('')
  $reviewLines.Add('| 用例 / 位置 | 问题类型 | 严重性 | 明确修复要求 |')
  $reviewLines.Add('|---|---|---|---|')
  foreach ($issue in $issues) {
    if ($null -ne $issue.differenceBounds) {
      $bounds = $issue.differenceBounds
      $location = "$($issue.id)，x=$($bounds.left)–$($bounds.right)，y=$($bounds.top)–$($bounds.bottom)"
      $requirement = '先定位该区域对应的 Flutter 组件和状态；修复后重新构建固定预览并重新采集。未经设计批准不得更新基准。'
    } else {
      $location = "$($issue.id)，采集或环境阶段"
      $requirement = "按错误日志修复可复现条件；未经设计批准不得更新基准。错误：$($issue.error)"
    }
    $reviewLines.Add("| $location | 视觉回归 / 运行时差异 | 高 | $requirement |")
  }
}
$reviewLines.Add('')
$reviewLines.Add('本报告只覆盖 Windows 固定运行时；跨平台设备、真实远程来源和人工读屏仍需独立验收。')
$reviewLines | Set-Content -Encoding UTF8 (Join-Path $output 'visual-review.md')

Write-Output "Runtime visual result: $resultsPath"
if (!$overallPassed) {
  exit 1
}
exit 0
