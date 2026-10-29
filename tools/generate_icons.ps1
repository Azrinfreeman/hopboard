$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path -Parent $PSScriptRoot

function New-RoundedPath([single]$x, [single]$y, [single]$width, [single]$height, [single]$radius) {
    $path = [Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $radius * 2
    $path.AddArc($x, $y, $diameter, $diameter, 180, 90)
    $path.AddArc($x + $width - $diameter, $y, $diameter, $diameter, 270, 90)
    $path.AddArc($x + $width - $diameter, $y + $height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($x, $y + $height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-IconPng([int]$size) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.ScaleTransform($size / 256.0, $size / 256.0)
    $background = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(99, 91, 232))
    $outline = [Drawing.Pen]::new([Drawing.Color]::White, 13)
    $outline.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $outline.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $shape = New-RoundedPath 0 0 256 256 55
    $graphics.FillPath($background, $shape)
    $paper = New-RoundedPath 72 65 112 139 16
    $graphics.DrawPath($outline, $paper)
    $clip = New-RoundedPath 103 49 50 30 10
    $graphics.FillPath([Drawing.Brushes]::White, $clip)
    $graphics.DrawLine($outline, 101, 112, 155, 112)
    $graphics.DrawLine($outline, 101, 145, 155, 145)
    $graphics.DrawLine($outline, 101, 177, 133, 177)
    $stream = [IO.MemoryStream]::new()
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()
    $stream.Dispose(); $shape.Dispose(); $paper.Dispose(); $clip.Dispose()
    $outline.Dispose(); $background.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    return ,$bytes
}

$sizes = @(32, 48, 256)
$frames = @($sizes | ForEach-Object { ,(New-IconPng $_) })
$iconFile = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
$iconStream = [IO.File]::Create($iconFile)
$writer = [IO.BinaryWriter]::new($iconStream)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + $sizes.Count * 16
for ($index = 0; $index -lt $sizes.Count; $index++) {
    $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$frames[$index].Length); $writer.Write([uint32]$offset)
    $offset += $frames[$index].Length
}
foreach ($frame in $frames) { $writer.Write([byte[]]$frame) }
$writer.Dispose(); $iconStream.Dispose()

$androidSizes = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($density in $androidSizes.Keys) {
    [IO.File]::WriteAllBytes((Join-Path $projectRoot "android\app\src\main\res\mipmap-$density\ic_launcher.png"),
        (New-IconPng $androidSizes[$density]))
}
$iosIcons = Join-Path $projectRoot 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
Get-ChildItem -LiteralPath $iosIcons -Filter '*.png' | ForEach-Object {
    if ($_.Name -match 'Icon-App-([0-9.]+)x[0-9.]+@([123])x') {
        $pixels = [int]([double]$Matches[1] * [int]$Matches[2])
        [IO.File]::WriteAllBytes($_.FullName, (New-IconPng $pixels))
    }
}
Write-Output 'LocalClipboard icons generated for Windows, Android, and iPhone.'
