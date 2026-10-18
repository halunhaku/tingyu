param([string]$EngineRoot = (Join-Path $PSScriptRoot '../app/build/flutter-engine'))
$ErrorActionPreference = 'Stop'
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$pythonLocation = Join-Path $EngineRoot 'python-location.txt'
$enginePython = if (Test-Path -LiteralPath $pythonLocation) { (Get-Content $pythonLocation -Raw).Trim() } else {
  Get-ChildItem (Join-Path $EngineRoot 'vpython/store') -Directory -Filter 'cpython*' |
    ForEach-Object { Join-Path $_.FullName 'contents/bin/python3.exe' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (!$enginePython -or !(Test-Path -LiteralPath $enginePython)) { throw 'Bootstrap CPython with depot_tools or bootstrap-windows-engine.ps1 before using this environment.' }
$env:PATH = (Split-Path $enginePython) + ';' + (Join-Path $PSScriptRoot 'win-engine-shims') + ';' + (Join-Path $EngineRoot 'depot_tools') + ';' + $env:PATH
$env:TINGYU_ENGINE_PYTHON = $enginePython
$env:PYTHONPATH = Join-Path $EngineRoot 'python-deps'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:DEPOT_TOOLS_UPDATE = '0'
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$visualStudio) { throw 'Visual Studio C++ tools were not found.' }
$env:GYP_MSVS_OVERRIDE_PATH = $visualStudio.Trim()
$env:WINDOWSSDKDIR = 'C:/Program Files (x86)/Windows Kits/10'
$env:VPYTHON_VIRTUALENV_ROOT = Join-Path $EngineRoot 'vpython'
$env:CIPD_CACHE_DIR = Join-Path $EngineRoot 'cipd-cache'
# Use the isolated, pinned Python dependencies rather than Google's Python index,
# whose bootstrap fails under this machine's Chinese Windows locale.
$env:VPYTHON_BYPASS = 'manually managed python not supported by chrome operations'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_0 = 'true'
