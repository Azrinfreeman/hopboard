param()
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
Push-Location $workspace
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    $bundle = Join-Path $workspace 'build/windows/x64/runner/Release'
    $output = Join-Path $workspace 'dist'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $archive = Join-Path $output 'Hopboard-Windows-x64.zip'
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -Force
    $checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$archive.sha256" -Value "$checksum  Hopboard-Windows-x64.zip" -Encoding ascii
    Write-Output "Created $archive"
} finally {
    Pop-Location
}
