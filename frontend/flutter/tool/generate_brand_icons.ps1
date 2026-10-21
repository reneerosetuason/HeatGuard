# Package the supplied brand artwork at native launcher sizes on Windows.
# Run from any directory: powershell -File frontend/flutter/tool/generate_brand_icons.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$flutterRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$markPath = Join-Path $flutterRoot 'assets/branding/heatguard_mark.png'
$mark = [System.Drawing.Bitmap]::FromFile($markPath)
$cream = [System.Drawing.ColorTranslator]::FromHtml('#F7F4EC')

function Write-BrandIcon {
    param([string]$RelativePath, [int]$Size, [double]$Scale = 0.88,
          [switch]$Transparent, [switch]$Monochrome)
    $path = Join-Path $flutterRoot $RelativePath
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null
    $format = if ($Transparent) { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb }
              else { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb }
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, $format)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $attributes = $null
    try {
        if ($Transparent) { $graphics.Clear([System.Drawing.Color]::Transparent) }
        else { $graphics.Clear($cream) }
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $edge = [int][Math]::Round($Size * $Scale)
        $offset = [int][Math]::Round(($Size - $edge) / 2.0)
        $rectangle = New-Object System.Drawing.Rectangle($offset, $offset, $edge, $edge)
        if ($Monochrome) {
            # Android notification and themed launcher icons use the artwork's alpha.
            $matrix = New-Object System.Drawing.Imaging.ColorMatrix
            $matrix.Matrix00 = 0; $matrix.Matrix11 = 0; $matrix.Matrix22 = 0
            $matrix.Matrix40 = 1; $matrix.Matrix41 = 1; $matrix.Matrix42 = 1
            $attributes = New-Object System.Drawing.Imaging.ImageAttributes
            $attributes.SetColorMatrix($matrix)
            $graphics.DrawImage($mark, $rectangle, 0, 0, $mark.Width, $mark.Height,
                [System.Drawing.GraphicsUnit]::Pixel, $attributes)
        } else {
            $graphics.DrawImage($mark, $rectangle)
        }
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        if ($attributes) { $attributes.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $densities = @(
        @{Name='mdpi'; Factor=1}, @{Name='hdpi'; Factor=1.5},
        @{Name='xhdpi'; Factor=2}, @{Name='xxhdpi'; Factor=3},
        @{Name='xxxhdpi'; Factor=4}
    )
    foreach ($density in $densities) {
        $resources = 'android/app/src/main/res'
        $mipmap = "$resources/mipmap-$($density.Name)"
        $drawable = "$resources/drawable-$($density.Name)"
        Write-BrandIcon "$mipmap/ic_launcher.png" ([int](48*$density.Factor))
        # Keep the emblem within the adaptive icon's central safe area.
        Write-BrandIcon "$mipmap/ic_launcher_foreground.png" ([int](108*$density.Factor)) -Scale 0.68 -Transparent
        Write-BrandIcon "$mipmap/ic_launcher_monochrome.png" ([int](108*$density.Factor)) -Scale 0.68 -Transparent -Monochrome
        Write-BrandIcon "$drawable/ic_stat_heatguard.png" ([int](24*$density.Factor)) -Scale 0.96 -Transparent -Monochrome
        Write-BrandIcon "$drawable/heatguard_splash.png" ([int](144*$density.Factor)) -Transparent
    }
    Write-BrandIcon 'web/favicon.png' 48 -Scale 0.96
    foreach ($size in @(192,512)) {
        Write-BrandIcon "web/icons/Icon-$size.png" $size
        Write-BrandIcon "web/icons/Icon-maskable-$size.png" $size -Scale 0.72
    }
    $iosDirectory = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    $catalog = Get-Content -LiteralPath (Join-Path $flutterRoot "$iosDirectory/Contents.json") -Raw | ConvertFrom-Json
    foreach ($group in ($catalog.images | Group-Object filename)) {
        $entry = $group.Group[0]
        $pixels = [int]([double]($entry.size.Split('x')[0]) * [double]($entry.scale.TrimEnd('x')))
        Write-BrandIcon "$iosDirectory/$($entry.filename)" $pixels
    }
    Write-Output 'HeatGuard Android, iOS and web icons generated.'
} finally {
    $mark.Dispose()
}
