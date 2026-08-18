param(
    [Parameter(Mandatory)][string]$SourceIcon
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$source = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $SourceIcon).Path)
try {
    $width = $source.Width
    $height = $source.Height
    $candidate = New-Object 'bool[,]' $width, $height
    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x++) {
            $pixel = $source.GetPixel($x, $y)
            $candidate[$x, $y] = $pixel.R -ge 95 -and ($pixel.R - $pixel.G) -ge 45 -and ($pixel.R - $pixel.B) -ge 55
        }
    }

    $visited = New-Object 'bool[,]' $width, $height
    $largest = New-Object System.Collections.Generic.List[System.Drawing.Point]
    for ($startY = 0; $startY -lt $height; $startY++) {
        for ($startX = 0; $startX -lt $width; $startX++) {
            if (-not $candidate[$startX, $startY] -or $visited[$startX, $startY]) { continue }
            $component = New-Object System.Collections.Generic.List[System.Drawing.Point]
            $queue = New-Object 'System.Collections.Generic.Queue[System.Drawing.Point]'
            $queue.Enqueue((New-Object System.Drawing.Point $startX, $startY))
            $visited[$startX, $startY] = $true
            while ($queue.Count -gt 0) {
                $point = $queue.Dequeue()
                $component.Add($point)
                for ($dy = -1; $dy -le 1; $dy++) {
                    for ($dx = -1; $dx -le 1; $dx++) {
                        if ($dx -eq 0 -and $dy -eq 0) { continue }
                        $nextX = $point.X + $dx
                        $nextY = $point.Y + $dy
                        if ($nextX -lt 0 -or $nextY -lt 0 -or $nextX -ge $width -or $nextY -ge $height) { continue }
                        if ($candidate[$nextX, $nextY] -and -not $visited[$nextX, $nextY]) {
                            $visited[$nextX, $nextY] = $true
                            $queue.Enqueue((New-Object System.Drawing.Point $nextX, $nextY))
                        }
                    }
                }
            }
            if ($component.Count -gt $largest.Count) { $largest = $component }
        }
    }
    if ($largest.Count -lt 100) { throw 'The red symbol could not be isolated from the source icon.' }

    $minX = ($largest.X | Measure-Object -Minimum).Minimum
    $maxX = ($largest.X | Measure-Object -Maximum).Maximum
    $minY = ($largest.Y | Measure-Object -Minimum).Minimum
    $maxY = ($largest.Y | Measure-Object -Maximum).Maximum
    $maskWidth = $maxX - $minX + 1
    $maskHeight = $maxY - $minY + 1
    $mask = New-Object System.Drawing.Bitmap $maskWidth, $maskHeight, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        foreach ($point in $largest) {
            $mask.SetPixel($point.X - $minX, $point.Y - $minY, [System.Drawing.Color]::White)
        }

        $redLayer = New-Object System.Drawing.Bitmap $maskWidth, $maskHeight, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $greenLayer = New-Object System.Drawing.Bitmap $maskWidth, $maskHeight, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $frontColor = [System.Drawing.Color]::FromArgb(255, 229, 70, 35)
            $rearColor = [System.Drawing.Color]::FromArgb(255, 165, 232, 177)
            for ($y = 0; $y -lt $maskHeight; $y++) {
                for ($x = 0; $x -lt $maskWidth; $x++) {
                    if ($mask.GetPixel($x, $y).A -gt 0) {
                        $redLayer.SetPixel($x, $y, $frontColor)
                        $greenLayer.SetPixel($x, $y, $rearColor)
                    }
                }
            }

            $canvas = New-Object System.Drawing.Bitmap 512, 512, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($canvas)
                try {
                    $graphics.Clear([System.Drawing.Color]::Transparent)
                    $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
                    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

                    $anchorX = 150.0
                    $anchorY = 445.0
                    $symbolSize = 300.0
                    $saved = $graphics.Save()
                    try {
                        $graphics.TranslateTransform($anchorX, $anchorY)
                        $graphics.RotateTransform(-20.0)
                        $graphics.DrawImage($greenLayer, 0.0, -$symbolSize, $symbolSize, $symbolSize)
                    } finally {
                        $graphics.Restore($saved)
                    }
                    $graphics.DrawImage($redLayer, $anchorX, $anchorY - $symbolSize, $symbolSize, $symbolSize)
                } finally {
                    $graphics.Dispose()
                }
                $outputPath = Join-Path $PSScriptRoot 'assets\Dota2TerrainSwitcher.png'
                $canvas.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-Output $outputPath
            } finally {
                $canvas.Dispose()
            }
        } finally {
            $redLayer.Dispose()
            $greenLayer.Dispose()
        }
    } finally {
        $mask.Dispose()
    }
} finally {
    $source.Dispose()
}
