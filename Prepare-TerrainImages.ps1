param(
    [Parameter(Mandatory)][string]$SourceSheet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$outputDirectory = Join-Path $PSScriptRoot 'assets\terrains'
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory)
}

# Coordinates correspond to the artwork-only areas in the normalized 1340 x 1174 source sheet.
$tiles = @(
    [pscustomobject]@{ File = 'dota_ti10.png';     X = 33;   Y = 55;  Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_journey.png';  X = 680;  Y = 55;  Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_jungle.png';   X = 1003; Y = 55;  Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_summer.png';   X = 33;   Y = 441; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_cavern.png';   X = 356;  Y = 441; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_spring.png';   X = 680;  Y = 441; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_reef.png';     X = 1003; Y = 441; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_autumn.png';   X = 33;   Y = 828; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_coloseum.png'; X = 356;  Y = 828; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_winter.png';   X = 680;  Y = 828; Width = 304; Height = 202 },
    [pscustomobject]@{ File = 'dota_desert.png';   X = 1003; Y = 828; Width = 304; Height = 202 }
)

$source = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $SourceSheet).Path)
try {
    if ($source.Width -ne 1340 -or $source.Height -ne 1174) {
        throw "Unexpected source-sheet dimensions: $($source.Width) x $($source.Height)."
    }

    $samples = @()
    foreach ($tile in $tiles) {
        $sum = 0.0
        $count = 0
        for ($y = $tile.Y; $y -lt ($tile.Y + $tile.Height); $y += 3) {
            for ($x = $tile.X; $x -lt ($tile.X + $tile.Width); $x += 3) {
                $pixel = $source.GetPixel($x, $y)
                $sum += (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                $count++
            }
        }
        $samples += [pscustomobject]@{ Tile = $tile; Luminance = ($sum / $count) }
    }
    $ordered = @($samples.Luminance | Sort-Object)
    $targetLuminance = [double]$ordered[[int][Math]::Floor($ordered.Count / 2)]

    foreach ($sample in $samples) {
        $factor = $targetLuminance / [double]$sample.Luminance
        $factor = [Math]::Max(0.72, [Math]::Min(1.45, $factor))
        $destination = New-Object System.Drawing.Bitmap 456, 304, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($destination)
            try {
                $graphics.Clear([System.Drawing.Color]::Black)
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $attributes = New-Object System.Drawing.Imaging.ImageAttributes
                try {
                    $matrix = New-Object System.Drawing.Imaging.ColorMatrix
                    $matrix.Matrix00 = [single]$factor
                    $matrix.Matrix11 = [single]$factor
                    $matrix.Matrix22 = [single]$factor
                    $attributes.SetColorMatrix($matrix)
                    $destinationRectangle = New-Object System.Drawing.Rectangle 0, 0, 456, 304
                    $graphics.DrawImage(
                        $source,
                        $destinationRectangle,
                        $sample.Tile.X,
                        $sample.Tile.Y,
                        $sample.Tile.Width,
                        $sample.Tile.Height,
                        [System.Drawing.GraphicsUnit]::Pixel,
                        $attributes)
                } finally {
                    $attributes.Dispose()
                }
            } finally {
                $graphics.Dispose()
            }
            $outputPath = Join-Path $outputDirectory $sample.Tile.File
            $destination.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Output ("{0}: source luminance {1:N1}, factor {2:N3}" -f $sample.Tile.File, $sample.Luminance, $factor)
        } finally {
            $destination.Dispose()
        }
    }
    Write-Output ("Target luminance: {0:N1}" -f $targetLuminance)
} finally {
    $source.Dispose()
}
