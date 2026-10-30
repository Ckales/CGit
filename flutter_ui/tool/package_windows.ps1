param(
    [string]$Version,
    [string]$OutputDir = (Join-Path $PSScriptRoot '../../dist')
)

$ErrorActionPreference = 'Stop'
if (-not $Version) {
    $pubspec = Get-Content (Join-Path $PSScriptRoot '../pubspec.yaml') -Raw
    $Version = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid release version: $Version" }

$release = Join-Path $PSScriptRoot '../build/windows/x64/runner/Release'
foreach ($file in @('CGit.exe', 'flutter_windows.dll', 'cgit_rust.dll', 'data/icudtl.dat')) {
    if (-not (Test-Path (Join-Path $release $file))) { throw "Missing build file: $file" }
}
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path $compiler)) { throw 'Install Inno Setup 6 before packaging.' }

$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$stage = Join-Path ([IO.Path]::GetTempPath()) ('CGit-package-' + [guid]::NewGuid())
New-Item -ItemType Directory $stage | Out-Null
try {
    Copy-Item -Path "$release/*" -Destination $stage -Recurse -Force
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsInstall = & $vswhere -latest -products * -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsInstall) { throw 'Cannot locate Visual Studio.' }
    $redist = Join-Path $vsInstall 'VC/Redist/MSVC'
    foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $source = Get-ChildItem $redist -Recurse -Filter $dll |
            Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT\\' } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $source) { throw "Missing VC++ runtime: $dll" }
        Copy-Item $source.FullName $stage
    }
    & $compiler "/DAppVersion=$Version" "/DSourceDir=$stage" "/O$OutputDir" (Join-Path $PSScriptRoot 'windows_installer.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
    $installer = Join-Path $OutputDir "CGit-$Version-windows-x64-Setup.exe"
    if (-not (Test-Path $installer)) { throw "Missing installer: $installer" }
    Write-Output $installer
} finally {
    Remove-Item $stage -Recurse -Force
}
