param(
    [Parameter(Mandatory = $true)][string]$ArchivePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing
$repository = Split-Path $PSScriptRoot -Parent
$assets = Join-Path $repository 'App/Assets.xcassets'
$sourceRoot = Join-Path $repository 'design/brand'
$expectedHash = 'B25A07F1262B1CE81F2DA7C25DEC31022A364BCE8B8B934B3D4E225227FC61B4'
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath).Path)
try {
    foreach ($source in @(
        @{ Entry = 'zhifi-final/zhifi-icon-1024.png'; Name = 'zirox-icon-1024.png' },
        @{ Entry = 'zhifi-final/zhifi-icon.svg'; Name = 'zirox-icon.svg' }
    )) {
        $entry = $archive.GetEntry($source.Entry)
        if ($null -eq $entry) { throw "Missing supplied icon: $($source.Entry)" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $sourceRoot $source.Name), $true)
    }
} finally { $archive.Dispose() }

$sourcePath = Join-Path $sourceRoot 'zirox-icon-1024.png'
if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'The source PNG does not match the user-approved icon.'
}
$sourceImage = [System.Drawing.Bitmap]::new($sourcePath)
try {
    if ($sourceImage.Width -ne 1024 -or $sourceImage.Height -ne 1024) {
        throw 'The supplied icon must be 1024 by 1024 pixels.'
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $assets 'AppIcon.appiconset/AppIcon-1024.png') -Force
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $assets 'BrandIcon.imageset/BrandIcon.png') -Force
    $sizes = @{
        'AppIcon.appiconset/AppIcon-20@2x.png' = 40
        'AppIcon.appiconset/AppIcon-20@3x.png' = 60
        'AppIcon.appiconset/AppIcon-29@2x.png' = 58
        'AppIcon.appiconset/AppIcon-29@3x.png' = 87
        'AppIcon.appiconset/AppIcon-40@2x.png' = 80
        'AppIcon.appiconset/AppIcon-40@3x.png' = 120
        'AppIcon.appiconset/AppIcon-60@2x.png' = 120
        'AppIcon.appiconset/AppIcon-60@3x.png' = 180
        'LaunchIcon.imageset/LaunchIcon.png' = 72
        'LaunchIcon.imageset/LaunchIcon@2x.png' = 144
        'LaunchIcon.imageset/LaunchIcon@3x.png' = 216
    }
    foreach ($asset in $sizes.GetEnumerator()) {
        $target = [System.Drawing.Bitmap]::new($asset.Value, $asset.Value, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [System.Drawing.Graphics]::FromImage($target)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($sourceImage, 0, 0, $asset.Value, $asset.Value)
            $target.Save((Join-Path $assets $asset.Key), [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $target.Dispose() }
    }
} finally { $sourceImage.Dispose() }
Write-Output 'Imported the supplied icon into AppIcon, BrandIcon and LaunchIcon assets.'
