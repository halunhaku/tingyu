param([Parameter(Mandatory=$true)][string]$PythonExecutable,
      [string]$FrameworkSourceUri = 'https://github.com/flutter/flutter.git',
      [string]$EngineRoot = (Join-Path $PSScriptRoot '../app/build/flutter-engine'))
$ErrorActionPreference = 'Stop'
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$PythonExecutable = (Resolve-Path -LiteralPath $PythonExecutable).Path
$manifest = Get-Content (Join-Path $PSScriptRoot 'engine-patches/windows-engine.json') -Raw | ConvertFrom-Json
& $PythonExecutable -c 'import sys; assert sys.version_info[:3] == (3, 11, 9), sys.version'
if ($LASTEXITCODE -ne 0) { throw 'The engine bootstrap requires CPython 3.11.9.' }
New-Item -ItemType Directory -Force $EngineRoot | Out-Null
$checkout = Join-Path $EngineRoot 'checkout'
$depot = Join-Path $EngineRoot 'depot_tools'
foreach ($repository in @(
  @{path=$checkout; uri=$FrameworkSourceUri; revision=$manifest.frameworkRevision},
  @{path=$depot; uri='https://chromium.googlesource.com/chromium/tools/depot_tools.git'; revision=$manifest.depotToolsRevision}
)) {
  if (!(Test-Path -LiteralPath (Join-Path $repository.path '.git'))) {
    if (Test-Path -LiteralPath $repository.path) { throw 'Refusing to clone over an existing non-Git directory.' }
    & git clone --depth 1 --no-checkout $repository.uri $repository.path
    if ($LASTEXITCODE -ne 0) { throw 'Cloning engine build sources failed.' }
    & git -C $repository.path config core.longpaths true
    & git -C $repository.path fetch --depth 1 origin $repository.revision
    if ($LASTEXITCODE -ne 0) { throw 'Fetching pinned build revision failed.' }
    & git -C $repository.path checkout --detach $repository.revision
    if ($LASTEXITCODE -ne 0) { throw 'Checking out pinned build revision failed.' }
  }
  $revision = & git -C $repository.path rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $revision -ne $repository.revision) { throw 'Existing build source differs from the pinned revision.' }
}
$gclient = @'
solutions = [{
  "name": ".",
  "url": "https://github.com/flutter/flutter.git",
  "managed": False,
  "deps_file": "DEPS",
  "custom_deps": {},
  "custom_vars": {
    "download_android_deps": False,
    "download_linux_deps": False,
    "download_fuchsia_deps": False,
    "download_emsdk": False,
    "setup_githooks": False,
  },
}]
'@
$gclientPath = Join-Path $checkout '.gclient'
if (!(Test-Path -LiteralPath $gclientPath)) {
  [IO.File]::WriteAllText($gclientPath,$gclient,[Text.UTF8Encoding]::new($false))
}
[IO.File]::WriteAllText((Join-Path $EngineRoot 'python-location.txt'),$PythonExecutable,[Text.UTF8Encoding]::new($false))
& $PythonExecutable -m pip install --target (Join-Path $EngineRoot 'python-deps') -r (Join-Path $PSScriptRoot 'engine-patches/python-requirements.txt') --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { throw 'Installing pinned engine Python dependencies failed.' }
Write-Output "Prepared pinned engine workspace: $EngineRoot"
