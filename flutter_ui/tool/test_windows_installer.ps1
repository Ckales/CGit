param([Parameter(Mandatory)][string]$Installer)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path ([IO.Path]::GetTempPath()) ('CGit-install-test-' + [guid]::NewGuid())
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'CGit.lnk'
$arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$installDir`"")
try {
    # Install twice to exercise upgrading the existing installation as well.
    foreach ($attempt in 1..2) {
        $process = Start-Process -FilePath $Installer -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Installation $attempt failed: $($process.ExitCode)" }
        foreach ($file in @('CGit.exe', 'flutter_windows.dll', 'cgit_rust.dll', 'data/icudtl.dat',
                'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'unins000.exe')) {
            if (-not (Test-Path (Join-Path $installDir $file))) { throw "Missing installed file: $file" }
        }
    }
    if (-not (Test-Path $shortcut)) { throw 'Missing Start menu shortcut.' }
} finally {
    $uninstaller = Join-Path $installDir 'unins000.exe'
    if (Test-Path $uninstaller) {
        $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Uninstall failed: $($process.ExitCode)" }
        if (Test-Path (Join-Path $installDir 'CGit.exe')) { throw 'Uninstall left CGit.exe behind.' }
        if (Test-Path $shortcut) { throw 'Uninstall left the Start menu shortcut behind.' }
    }
}
