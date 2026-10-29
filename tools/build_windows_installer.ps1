param(
    [switch]$SkipBuild,
    [string]$InnoCompiler,
    [string]$VCRuntimeDirectory
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot

if (-not $InnoCompiler) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $InnoCompiler = $command.Source }
    foreach ($candidate in @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if (-not $InnoCompiler -and (Test-Path -LiteralPath $candidate)) {
            $InnoCompiler = $candidate
        }
    }
}
if (-not $InnoCompiler -or -not (Test-Path -LiteralPath $InnoCompiler)) {
    throw 'Install Inno Setup 6 or pass -InnoCompiler with the path to ISCC.exe.'
}
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_windows.ps1')
}
$bundle = Join-Path $workspace 'build/windows/x64/runner/Release'
$executable = Join-Path $bundle 'local_clipboard.exe'
foreach ($required in @('local_clipboard.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) {
        throw "Missing Windows release file: $required. Build the release first."
    }
}
$metadata = (Get-Item -LiteralPath $executable).VersionInfo
$version = $metadata.ProductVersion -replace '\+.*$', ''
$fileVersion = '{0}.{1}.{2}.{3}' -f $metadata.FileMajorPart, $metadata.FileMinorPart, $metadata.FileBuildPart, $metadata.FilePrivatePart
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Unexpected executable version.' }

if (-not $VCRuntimeDirectory) {
    $candidates = Get-ChildItem -Path "$env:ProgramFiles\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT" -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    $VCRuntimeDirectory = $candidates | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'vcruntime140_1.dll')
    } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $VCRuntimeDirectory) { throw 'Pass -VCRuntimeDirectory with the Visual Studio x64 CRT redistributable directory.' }

# A fresh staging directory avoids stale files without deleting a prior build.
$stage = Join-Path $workspace ('build/installer-stage/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -Path (Join-Path $bundle '*') -Destination $stage -Recurse
foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $source = Join-Path $VCRuntimeDirectory $runtime
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing x64 CRT redistributable: $source" }
    Copy-Item -LiteralPath $source -Destination $stage
}
$output = Join-Path $workspace 'dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
& $InnoCompiler "/DBundleDir=$stage" "/DAppVersion=$version" "/DFileVersion=$fileVersion" "/DOutputDir=$output" "/DAppIcon=$(Join-Path $workspace 'windows/runner/resources/app_icon.ico')" (Join-Path $PSScriptRoot 'windows_installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
$installer = Join-Path $output "LocalClipboard-Setup-$version-x64.exe"
$checksum = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$installer.sha256" -Value "$checksum  $(Split-Path -Leaf $installer)" -Encoding ascii
Write-Output "Created $installer"
