[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$versionFile = Join-Path $root 'VERSION'
if ([string]::IsNullOrWhiteSpace($Version)) {
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw "找不到版本文件：$versionFile"
    }
    $Version = [System.IO.File]::ReadAllText($versionFile, [System.Text.Encoding]::UTF8).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw "版本号格式无效：$Version"
}

Write-Host "== Dota 2 地图替换器：一键检查并构建 ==" -ForegroundColor Cyan
Write-Host "项目目录：$root"
Write-Host "构建版本：v$Version"
Write-Host ""

# Windows PowerShell 5.1 对 UTF-8 无 BOM 的中文 .ps1 兼容不好。
# 构建前统一把项目根目录中的所有 PowerShell 脚本转换为 UTF-8 with BOM。
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | ForEach-Object {
    $path = $_.FullName

    # 按 UTF-8 读取源码，再以 UTF-8 BOM 写回。
    # 这不会修改代码内容，只统一文件编码。
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($path, $text, $utf8Bom)

    Write-Host ("[编码] " + $_.Name + " -> UTF-8 BOM")
}

Write-Host ""
Write-Host "== 运行 SelfTest ==" -ForegroundColor Cyan

$mainScript = Join-Path $root 'Dota2TerrainSwitcher.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    throw "找不到主脚本：$mainScript"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "SelfTest 失败，已停止构建。"
}

Write-Host ""
Write-Host "== 重新生成 dist ==" -ForegroundColor Cyan

$buildScript = Join-Path $root 'Build-Dota2TerrainSwitcher.ps1'
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "找不到构建脚本：$buildScript"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -Version $Version
if ($LASTEXITCODE -ne 0) {
    throw "构建失败。"
}

Write-Host ""
Write-Host "== 完成 ==" -ForegroundColor Green
Write-Host "发布文件位于："
Write-Host (Join-Path $root 'dist')
