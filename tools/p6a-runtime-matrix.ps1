param(
  [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
  [string]$AppDirectory,
  [string]$CasesFile = 'docs/ui-redesign/p6a-quality/runtime-matrix.json',
  [string]$OutputDirectory = 'docs/ui-redesign/p6a-evidence/runtime-matrix',
  [int]$WaitSeconds = 5
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
$contactSheet = Join-Path $PSScriptRoot 'windows-ui-contact-sheet.ps1'
$pwsh = (Get-Process -Id $PID).Path

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw 'P6A runtime matrix requires Windows because it uses fixed Windows DPI and font rasterization.'
}
if (!(Test-Path -LiteralPath $casesPath -PathType Leaf)) {
  throw "P6A runtime matrix manifest not found: $casesPath"
}
if (!(Test-Path -LiteralPath (Join-Path $app 'tingyu.exe') -PathType Leaf)) {
  throw "Built Flutter preview executable not found: $(Join-Path $app 'tingyu.exe')"
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$matrixImages = Join-Path $output 'matrix-images'
New-Item -ItemType Directory -Force -Path $matrixImages | Out-Null

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

$config = Get-Content -LiteralPath $casesPath -Raw | ConvertFrom-Json
if (!$config.diagnosticOnly -or $config.approvedBaseline) {
  throw 'The P6A matrix must remain diagnostic-only and must not define or update an approved baseline.'
}
$required = $config.requiredEnvironment
if ($required.platform -ne 'windows') {
  throw "Unsupported required platform in matrix manifest: $($required.platform)"
}
if (![bool]$required.animationsDisabled) {
  throw 'P6A runtime matrix requires disabled animations.'
}

$fixturePath = Resolve-RepositoryPath $config.fixture
$coverPath = Resolve-RepositoryPath $config.fixtureCover
if (!(Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
  throw "Preview fixture not found: $fixturePath"
}
if (!(Test-Path -LiteralPath $coverPath -PathType Leaf)) {
  throw "Fixture cover not found: $coverPath"
}
$fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
$coverHash = (Get-FileHash -LiteralPath $coverPath -Algorithm SHA256).Hash.ToLowerInvariant()
$fonts = @(
  foreach ($font in @($required.fonts)) {
    [ordered]@{
      path = $font.path
      sha256 = (Get-FileHash -LiteralPath $font.path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
)
foreach ($font in @($required.fonts)) {
  [void](Assert-FileHash $font.path $font.sha256 "Required font $($font.path)")
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

$caseIds = @($config.cases | ForEach-Object { [string]$_.id })
if ($caseIds.Count -ne @($caseIds | Sort-Object -Unique).Count) {
  throw 'P6A runtime matrix contains duplicate case ids.'
}

Add-Type -AssemblyName System.Drawing
$caseResults = [Collections.Generic.List[object]]::new()
$overallPassed = $true
foreach ($case in @($config.cases)) {
  $caseDirectory = Join-Path $output $case.id
  New-Item -ItemType Directory -Force -Path $caseDirectory | Out-Null
  $captureLog = Join-Path $caseDirectory 'capture.log'

  try {
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
    $captureOutput = @(& $pwsh @captureArguments 2>&1)
    $captureExitCode = $LASTEXITCODE
    $captureOutput | Set-Content -Encoding UTF8 $captureLog
    if ($captureExitCode -ne 0) {
      throw "Runtime capture failed; see $captureLog"
    }

    $captureMetadataPath = Join-Path $caseDirectory 'capture-metadata.json'
    if (!(Test-Path -LiteralPath $captureMetadataPath -PathType Leaf)) {
      throw "Capture metadata not found: $captureMetadataPath"
    }
    $captureMetadata = Get-Content -LiteralPath $captureMetadataPath -Raw |
      ConvertFrom-Json
    $captures = @($captureMetadata.captures)
    if ($captures.Count -ne 1) {
      throw "Expected one capture for $($case.id), got $($captures.Count)."
    }
    $capture = $captures[0]
    if ([int]$capture.clientWidth -ne [int]$case.clientWidth -or
        [int]$capture.clientHeight -ne [int]$case.clientHeight) {
      throw "Client area mismatch for $($case.id): expected $($case.clientWidth)x$($case.clientHeight), got $($capture.clientWidth)x$($capture.clientHeight)"
    }
    if ([Math]::Abs([double]$capture.dpiScale - [double]$required.dpiScale) -gt 0.01) {
      throw "DPI mismatch for $($case.id): expected $($required.dpiScale), got $($capture.dpiScale)"
    }
    if ($capture.theme -ne $case.theme -or
        $capture.previewState -ne $case.previewState -or
        [double]$capture.previewScale -ne [double]$case.previewScale -or
        $capture.previewCover -ne $case.cover -or
        !$capture.animationsDisabled) {
      throw "Capture metadata does not match requested state for $($case.id)."
    }

    $actualPath = Join-Path $caseDirectory $case.captureFile
    if (!(Test-Path -LiteralPath $actualPath -PathType Leaf)) {
      throw "Expected screenshot not found: $actualPath"
    }
    $bitmap = [Drawing.Bitmap]::new($actualPath)
    try {
      $imageWidth = $bitmap.Width
      $imageHeight = $bitmap.Height
      $stepX = [Math]::Max(1, [Math]::Floor($bitmap.Width / 40))
      $stepY = [Math]::Max(1, [Math]::Floor($bitmap.Height / 40))
      $sampledColors = [Collections.Generic.HashSet[int]]::new()
      for ($y = 0; $y -lt $bitmap.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
          [void]$sampledColors.Add($bitmap.GetPixel($x, $y).ToArgb())
        }
      }
    } finally {
      $bitmap.Dispose()
    }
    if ($imageWidth -ne $case.clientWidth -or $imageHeight -ne $case.clientHeight) {
      throw "PNG dimensions mismatch for $($case.id): expected $($case.clientWidth)x$($case.clientHeight), got ${imageWidth}x${imageHeight}"
    }
    if ($sampledColors.Count -lt 2) {
      throw "Captured image appears blank for $($case.id)."
    }

    $flattenedPath = Join-Path $matrixImages "$($case.id).png"
    Copy-Item -LiteralPath $actualPath -Destination $flattenedPath -Force
    $actualHash = (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $caseResults.Add([ordered]@{
      id = $case.id
      page = $case.page
      route = $case.route
      intent = $case.intent
      logicalViewport = [ordered]@{
        width = $case.logicalWidth
        height = $case.logicalHeight
      }
      clientViewport = [ordered]@{
        width = $case.clientWidth
        height = $case.clientHeight
        dpiScale = $required.dpiScale
      }
      theme = $case.theme
      previewState = $case.previewState
      previewScale = $case.previewScale
      cover = $case.cover
      passedStructuralCheck = $true
      visualReview = 'capturedForManualReview'
      image = [IO.Path]::GetRelativePath($output, $actualPath).Replace('\', '/')
      flattenedImage = [IO.Path]::GetRelativePath($output, $flattenedPath).Replace('\', '/')
      sha256 = $actualHash
      captureMetadata = [IO.Path]::GetRelativePath($output, $captureMetadataPath).Replace('\', '/')
      captureLog = [IO.Path]::GetRelativePath($output, $captureLog).Replace('\', '/')
    })
  } catch {
    $overallPassed = $false
    $caseResults.Add([ordered]@{
      id = $case.id
      page = $case.page
      route = $case.route
      intent = $case.intent
      logicalViewport = [ordered]@{
        width = $case.logicalWidth
        height = $case.logicalHeight
      }
      clientViewport = [ordered]@{
        width = $case.clientWidth
        height = $case.clientHeight
        dpiScale = $required.dpiScale
      }
      theme = $case.theme
      previewState = $case.previewState
      previewScale = $case.previewScale
      cover = $case.cover
      passedStructuralCheck = $false
      visualReview = 'blocked'
      error = $_.Exception.Message
      captureLog = [IO.Path]::GetRelativePath($output, $captureLog).Replace('\', '/')
    })
  }
}

$contactSheetPath = Join-Path $output 'contact-sheet.png'
$capturedNames = @(
  $caseResults |
    Where-Object { $_.passedStructuralCheck } |
    ForEach-Object { [string]$_.id }
)
if ($capturedNames.Count -gt 0) {
  & $contactSheet `
    -InputDirectory $matrixImages `
    -OutputPath $contactSheetPath `
    -Names ([string[]]$capturedNames) `
    -Columns 3 `
    -TileWidth 560 `
    -TileHeight 340
}

$result = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToString('o')
  currentCommit = $gitCommit
  platform = 'Windows'
  diagnosticOnly = $true
  approvedBaseline = $false
  fixture = $config.fixture
  fixtureSha256 = $fixtureHash
  fixtureCover = $config.fixtureCover
  fixtureCoverSha256 = $coverHash
  flutter = $flutterIdentity
  fonts = $fonts
  animationsDisabled = $true
  overallStructuralPassed = $overallPassed
  contactSheet = [IO.Path]::GetRelativePath($output, $contactSheetPath).Replace('\', '/')
  cases = @($caseResults)
  limitations = @(
    'These captures are diagnostic evidence and have no approved pixel baseline.'
    'Structural capture success does not approve visual quality, layout polish, or cross-platform rendering.'
    'Windows fixed preview only; Android, iOS, macOS and Linux runtime rendering remain P6B work.'
    'Real Quark/WebDAV accounts, real devices, system text scaling and manual screen readers remain P6B work.'
  )
}
$resultsPath = Join-Path $output 'matrix-results.json'
$result | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $resultsPath

$review = [Collections.Generic.List[string]]::new()
$review.Add('# P6A 响应式运行时矩阵')
$review.Add('')
$review.Add("生成时间：$($result.generatedAt)")
$review.Add('')
$review.Add('本矩阵使用 Windows 固定数据预览、DPI 1.5、固定字体和关闭动画采集。')
$review.Add('它没有批准基准，不执行自动通过像素比较，也不能替代人工视觉审查或 P6B 设备验收。')
$review.Add('')
$review.Add('| 用例 | 逻辑视口 | 主题 / 字号 | 状态 | 结构检查 | 截图 |')
$review.Add('|---|---:|---|---|---|---|')
foreach ($caseResult in @($caseResults)) {
  $status = if ($caseResult.passedStructuralCheck) {
    '通过；待人工视觉审查'
  } else {
    "失败：$($caseResult.error)"
  }
  $themeScale = "$($caseResult.theme) / $([int]([double]$caseResult.previewScale * 100))%"
  $imageCell = if ($caseResult.passedStructuralCheck) {
    "[$($caseResult.id).png]($($caseResult.image))"
  } else {
    '—'
  }
  $review.Add(
    "| ``$($caseResult.id)`` | $($caseResult.logicalViewport.width)×$($caseResult.logicalViewport.height) | $themeScale | $($caseResult.previewState) | $status | $imageCell |"
  )
}
$review.Add('')
if ($overallPassed) {
  $review.Add('全部场景已完成尺寸、DPI、状态元数据与空白图检查；视觉结论必须基于联系表和原图人工审查另行填写。')
} else {
  $review.Add('矩阵存在采集或结构检查失败。按失败用例日志定位；不得删除用例或放宽检查掩盖问题。')
}
$review.Add('')
$review.Add('P6B 仍需覆盖 Android、iOS、macOS、Linux、真实设备触控、系统字体缩放、TalkBack/VoiceOver/Narrator 和真实账号服务。')
$review | Set-Content -Encoding UTF8 (Join-Path $output 'matrix-review.md')

Write-Output "P6A runtime matrix: $resultsPath"
if (!$overallPassed) {
  exit 1
}
exit 0
