[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = 'Stop'
$versionFile = Join-Path $PSScriptRoot 'VERSION'
if ([string]::IsNullOrWhiteSpace($Version)) {
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw "Version file is missing: $versionFile"
    }
    $Version = [System.IO.File]::ReadAllText($versionFile, [System.Text.Encoding]::UTF8).Trim()
}
if ($Version -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid semantic version: $Version"
}
$assemblyVersion = '{0}.{1}.{2}.0' -f $Matches.major, $Matches.minor, $Matches.patch

$distPath = Join-Path $PSScriptRoot 'dist'
if (-not (Test-Path -LiteralPath $distPath)) {
    [void](New-Item -ItemType Directory -Path $distPath)
}
$portablePath = Join-Path $distPath 'Dota2MapSwitcher-Portable'
if (Test-Path -LiteralPath $portablePath) {
    Remove-Item -LiteralPath $portablePath -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $portablePath)
$outputPath = Join-Path $portablePath 'Dota2MapSwitcher.exe'
$portableReadmeSource = Join-Path $PSScriptRoot 'PORTABLE-README.txt'
$portableReadmeOutput = Join-Path $portablePath '使用说明.txt'
$portableArchivePath = Join-Path $distPath 'Dota2MapSwitcher-Portable.zip'
$setupOutputPath = Join-Path $distPath 'Dota2MapSwitcherSetup.exe'
$legacyOutputPaths = @(
    (Join-Path $distPath 'Dota2MapSwitcher.exe'),
    (Join-Path $distPath 'Dota2TerrainSwitcher.exe')
)
foreach ($existingOutput in @($outputPath, $portableArchivePath, $setupOutputPath) + $legacyOutputPaths) {
    if (Test-Path -LiteralPath $existingOutput) {
        Remove-Item -LiteralPath $existingOutput -Force
    }
}
$legacyPortablePath = Join-Path $distPath 'Dota2MapSwitcher'
if (Test-Path -LiteralPath $legacyPortablePath -PathType Container) {
    Remove-Item -LiteralPath $legacyPortablePath -Recurse -Force
}
$scriptPath = Join-Path $PSScriptRoot 'Dota2TerrainSwitcher.ps1'
# The catalog is embedded into the EXE below. After changing terrain mappings,
# rebuild the EXE/installer so the corrected catalog is actually shipped.
$catalogPath = Join-Path $PSScriptRoot 'terrain-catalog.json'
$uiPath = Join-Path $PSScriptRoot 'ui.zh-CN.json'
$iconSourcePath = Join-Path $PSScriptRoot 'assets\Dota2TerrainSwitcher.png'
$iconPath = Join-Path $PSScriptRoot 'assets\Dota2TerrainSwitcher.ico'
$terrainImageDirectory = Join-Path $PSScriptRoot 'assets\terrains'
$terrainImages = @(Get-ChildItem -LiteralPath $terrainImageDirectory -Filter '*.png' -File | Sort-Object Name)
if ($terrainImages.Count -ne 11) {
    throw "Expected 11 terrain images, found $($terrainImages.Count)."
}
Add-Type -AssemblyName System.Drawing
$sourceImage = [System.Drawing.Image]::FromFile($iconSourcePath)
try {
    $bitmap = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.DrawImage($sourceImage, 0, 0, 256, 256)
        } finally { $graphics.Dispose() }
        $memory = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngBytes = $memory.ToArray()
        } finally { $memory.Dispose() }
    } finally { $bitmap.Dispose() }
} finally { $sourceImage.Dispose() }
$iconStream = [System.IO.File]::Create($iconPath)
try {
    $writer = New-Object System.IO.BinaryWriter $iconStream
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$pngBytes.Length)
        $writer.Write([uint32]22)
        $writer.Write($pngBytes)
    } finally { $writer.Dispose() }
} finally { $iconStream.Dispose() }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The .NET Framework C# compiler was not found.'
}
$automationAssembly = powershell.exe -NoProfile -Command '[System.Management.Automation.PSObject].Assembly.Location'
if ([string]::IsNullOrWhiteSpace($automationAssembly) -or -not (Test-Path -LiteralPath $automationAssembly -PathType Leaf)) {
    throw 'The Windows PowerShell automation assembly was not found.'
}
$buildMetadataDirectory = Join-Path $distPath '.build-metadata'
if (Test-Path -LiteralPath $buildMetadataDirectory) {
    Remove-Item -LiteralPath $buildMetadataDirectory -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $buildMetadataDirectory)
$assemblyInfoPath = Join-Path $buildMetadataDirectory 'AssemblyInfo.g.cs'
try {
    $assemblyInfoSource = @"
using System.Reflection;
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$Version")]
[assembly: AssemblyProduct("Dota 2 地图更换器")]
"@
    [System.IO.File]::WriteAllText($assemblyInfoPath, $assemblyInfoSource, (New-Object System.Text.UTF8Encoding($true)))
$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    ('/out:' + $outputPath),
    ('/win32icon:' + $iconPath),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    ('/reference:' + $automationAssembly),
    '/reference:System.Windows.Forms.dll',
    ('/resource:' + $scriptPath + ',Dota2TerrainSwitcher.ps1'),
    ('/resource:' + $catalogPath + ',terrain-catalog.json'),
    ('/resource:' + $uiPath + ',ui.zh-CN.json'),
    ('/resource:' + $iconPath + ',Dota2TerrainSwitcher.ico'),
    $assemblyInfoPath
)
foreach ($terrainImage in $terrainImages) {
    $compilerArguments += ('/resource:' + $terrainImage.FullName + ',terrains.' + $terrainImage.Name)
}
$compilerArguments += (Join-Path $PSScriptRoot 'RtsWinFormsDialog.cs')
$compilerArguments += (Join-Path $PSScriptRoot 'Dota2TerrainSwitcherLauncher.cs')
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw 'EXE compilation failed.'
}
# Keep the portable Chinese instructions readable in legacy Windows editors.
$portableReadmeText = [System.IO.File]::ReadAllText($portableReadmeSource, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($portableReadmeOutput, $portableReadmeText, (New-Object System.Text.UTF8Encoding($true)))

$installerBuildDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('Dota2MapSwitcherBuild_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $installerBuildDirectory)
try {
    $uninstallerOutputPath = Join-Path $installerBuildDirectory 'Uninstall.exe'
    $uninstallerArguments = @(
        '/nologo',
        '/target:winexe',
        ('/out:' + $uninstallerOutputPath),
        ('/win32icon:' + $iconPath),
        '/reference:System.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll',
        $assemblyInfoPath,
        (Join-Path $PSScriptRoot 'RtsWinFormsDialog.cs'),
        (Join-Path $PSScriptRoot 'Dota2MapSwitcherUninstaller.cs')
    )
    & $compiler @uninstallerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $uninstallerOutputPath -PathType Leaf)) {
        throw 'Uninstaller compilation failed.'
    }

    $installerArguments = @(
        '/nologo',
        '/target:winexe',
        ('/out:' + $setupOutputPath),
        ('/win32icon:' + $iconPath),
        '/reference:System.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll',
        ('/resource:' + $outputPath + ',Dota2MapSwitcher.exe'),
        ('/resource:' + $uninstallerOutputPath + ',Uninstall.exe'),
        $assemblyInfoPath,
        (Join-Path $PSScriptRoot 'RtsWinFormsDialog.cs'),
        (Join-Path $PSScriptRoot 'Dota2MapSwitcherInstaller.cs')
    )
    & $compiler @installerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setupOutputPath -PathType Leaf)) {
        throw 'Installer compilation failed.'
    }
} finally {
    if (Test-Path -LiteralPath $installerBuildDirectory) {
        Remove-Item -LiteralPath $installerBuildDirectory -Recurse -Force
    }
}

Compress-Archive -LiteralPath $portablePath -DestinationPath $portableArchivePath -CompressionLevel Optimal

Write-Output $outputPath
Write-Output $portableArchivePath
Write-Output $setupOutputPath
} finally {
    if (Test-Path -LiteralPath $buildMetadataDirectory) {
        Remove-Item -LiteralPath $buildMetadataDirectory -Recurse -Force
    }
}
