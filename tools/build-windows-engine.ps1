param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('Preflight','Sync','Configure','Compile','Test','App','Candidate')][string]$Stage,
  [int]$Jobs = 10,
  [string]$EngineRoot = (Join-Path $PSScriptRoot '../app/build/flutter-engine')
)
$ErrorActionPreference = 'Stop'
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$checkout = Join-Path $EngineRoot 'checkout'
$source = Join-Path $checkout 'engine/src'
$manifest = Get-Content (Join-Path $PSScriptRoot 'engine-patches/windows-engine.json') -Raw | ConvertFrom-Json
$patch = Join-Path $PSScriptRoot 'engine-patches/190903-null-parent.patch'
if ((Get-FileHash $patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.patchSha256) {
  throw 'Engine patch checksum does not match the pinned manifest.'
}
$combinedPatch = Join-Path $PSScriptRoot 'engine-patches/tingyu-accessibility.patch'
$fixturePatch = Join-Path $PSScriptRoot 'engine-patches/windows-test-aot-fixtures.patch'
if ((Get-FileHash $combinedPatch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.combinedPatchSha256 -or
    (Get-FileHash $fixturePatch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.testFixturePatchSha256) {
  throw 'Local engine patch checksums do not match the manifest.'
}
function Resolve-FlutterSdkDirectory {
  if (![string]::IsNullOrWhiteSpace($env:FLUTTER_ROOT)) {
    $candidate = $env:FLUTTER_ROOT.Trim()
    if (!(Test-Path -LiteralPath $candidate -PathType Container)) {
      throw "FLUTTER_ROOT does not point to a directory: $candidate"
    }
    return [IO.Path]::GetFullPath($candidate)
  }
  $flutterCommand = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (!$flutterCommand -or [string]::IsNullOrWhiteSpace($flutterCommand.Source)) {
    throw 'Unable to locate Flutter. Set FLUTTER_ROOT or add flutter to PATH.'
  }
  return [IO.Path]::GetFullPath((Join-Path (Split-Path $flutterCommand.Source -Parent) '..'))
}
function Assert-FlutterSdkRevision {
  $sdkDirectory = Resolve-FlutterSdkDirectory
  $sdkRevision = & git -C $sdkDirectory rev-parse HEAD 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sdkRevision)) {
    throw "Unable to read the Flutter SDK revision from '$sdkDirectory'."
  }
  $sdkRevision = $sdkRevision.Trim()
  Write-Output "Flutter SDK: $sdkDirectory ($sdkRevision)"
  if ($sdkRevision -ne $manifest.frameworkRevision) {
    throw "Flutter SDK revision mismatch. SDK root: '$sdkDirectory'; expected: '$($manifest.frameworkRevision)' (Flutter $($manifest.frameworkVersion)); actual: '$sdkRevision'."
  }
}
Assert-FlutterSdkRevision
if ($Stage -eq 'Preflight') {
  Write-Output 'Flutter SDK preflight passed.'
  return
}
$revision = & git -C $checkout rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $manifest.frameworkRevision) {
  throw 'Engine source checkout does not match the pinned Flutter revision.'
}
. (Join-Path $PSScriptRoot 'windows-engine-env.ps1') -EngineRoot $EngineRoot
$output = Join-Path $source ('out/' + $manifest.configuration)
Push-Location $checkout
try {
  switch ($Stage) {
    'Sync' {
      & gclient sync --no-history --nohooks -j $Jobs
      if ($LASTEXITCODE -ne 0) { throw 'Engine dependency sync failed.' }
      & gclient runhooks
      if ($LASTEXITCODE -ne 0) { throw 'Engine dependency hooks failed.' }
    }
    'Configure' {
      $sdkInclude = Join-Path $env:WINDOWSSDKDIR ('Include/' + $manifest.windowsSdkVersion)
      if (!(Test-Path -LiteralPath $sdkInclude)) { throw 'The pinned Windows SDK is not installed.' }
      $toolchainSetup = Join-Path $source 'build/toolchain/win/setup_toolchain.py'
      $toolchainText = [IO.File]::ReadAllText($toolchainSetup)
      $sdkSetting = "SDK_VERSION = '$($manifest.windowsSdkVersion)'"
      if (!$toolchainText.Contains($sdkSetting)) {
        if (!$toolchainText.Contains("SDK_VERSION = '10.0.22621.0'")) { throw 'Unexpected Windows SDK configuration in build dependency.' }
        [IO.File]::WriteAllText($toolchainSetup, $toolchainText.Replace("SDK_VERSION = '10.0.22621.0'", $sdkSetting), [Text.UTF8Encoding]::new($false))
      }
      $ErrorActionPreference = 'Continue'
      & git apply --reverse --check $combinedPatch 2>$null
      $patchApplied = $LASTEXITCODE -eq 0
      $ErrorActionPreference = 'Stop'
      if (!$patchApplied) {
        $ErrorActionPreference = 'Continue'
        & git apply --reverse --check $patch 2>$null
        $upstreamOnly = $LASTEXITCODE -eq 0
        $ErrorActionPreference = 'Stop'
        if ($upstreamOnly) { & git apply --reverse $patch }
        & git apply --check $combinedPatch
        if ($LASTEXITCODE -ne 0) { throw 'The combined engine patch cannot be applied.' }
        & git apply $combinedPatch
        if ($LASTEXITCODE -ne 0) { throw 'Applying the engine patch failed.' }
      }
      $ErrorActionPreference = 'Continue'
      & git apply --reverse --check $fixturePatch 2>$null
      $fixtureApplied = $LASTEXITCODE -eq 0
      $ErrorActionPreference = 'Stop'
      if (!$fixtureApplied) {
        & git apply --check $fixturePatch
        if ($LASTEXITCODE -ne 0) { throw 'The Windows test fixture patch cannot be applied.' }
        & git apply $fixturePatch
        if ($LASTEXITCODE -ne 0) { throw 'Applying the test fixture patch failed.' }
      }
      Push-Location $source
      try {
        & python3 flutter/tools/gn --runtime-mode=release --no-lto
        if ($LASTEXITCODE -ne 0) { throw 'Engine GN configuration failed.' }
      } finally { Pop-Location }
    }
    'Compile' {
      & (Join-Path $checkout 'third_party/ninja/ninja.exe') -C $output -j $Jobs windows gen_snapshot const_finder _font-subset common_cpp_unittests flutter_windows_unittests
      if ($LASTEXITCODE -ne 0) { throw 'Engine compilation failed.' }
    }
    'Test' {
      Push-Location $output
      try {
        & (Join-Path $output 'common_cpp_unittests.exe') '--gtest_filter=AccessibilityBridgeTest.*' '--gtest_output=xml:tingyu-common-accessibility.xml'
        if ($LASTEXITCODE -ne 0) { throw 'Accessibility bridge tests failed.' }
        & (Join-Path $output 'flutter_windows_unittests.exe') '--gtest_filter=*Accessibility*' '--gtest_output=xml:tingyu-windows-accessibility.xml'
        if ($LASTEXITCODE -ne 0) { throw 'Windows accessibility tests failed.' }
      } finally { Pop-Location }
    }
    'Candidate' {
      $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
      $candidate = Join-Path $repository 'app/build/windows-engine-candidate'
      $runningCandidate = Get-CimInstance Win32_Process -Filter "Name='tingyu.exe'" | Where-Object { $_.ExecutablePath -eq (Join-Path $candidate 'tingyu.exe') }
      if ($runningCandidate) { throw 'Close the previous candidate process before replacing its bundle.' }
      New-Item -ItemType Directory -Force $candidate | Out-Null
      Copy-Item -Path (Join-Path $repository 'app/build/windows/x64/runner/Release/*') -Destination $candidate -Recurse -Force
      Copy-Item -LiteralPath (Join-Path $output 'flutter_windows.dll') -Destination $candidate -Force
      Copy-Item -LiteralPath (Join-Path $output 'flutter_windows.dll.pdb') -Destination $candidate -Force
      $provenance = [ordered]@{
        manifest=$manifest
        engineDllSha256=(Get-FileHash (Join-Path $candidate 'flutter_windows.dll') -Algorithm SHA256).Hash
        builtAt=(Get-Date).ToString('o')
        note='Patched engine with restored MSAA access. Deploy only after this exact application bundle passes smoke tests.'
      }
      $provenance | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $candidate 'engine-provenance.json')
      Write-Output $candidate
    }
    'App' {
      & git apply --reverse --check $combinedPatch
      if ($LASTEXITCODE -ne 0) { throw 'The complete engine fix has not been applied to this checkout.' }
      Push-Location (Join-Path $PSScriptRoot '../app')
      try {
        & flutter "--local-engine-src-path=$source" "--local-engine=$($manifest.configuration)" "--local-engine-host=$($manifest.configuration)" build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Building the application with the patched engine failed.' }
      } finally { Pop-Location }
    }
  }
} finally { Pop-Location }
