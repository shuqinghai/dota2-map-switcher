[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('None','Patch','Minor','Major')][string]$Bump = 'None',
    [string]$NotesFile,
    [switch]$SkipBuild,
    [switch]$PublishGitHub
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$versionFile = Join-Path $root 'VERSION'
$publishRoot = Join-Path $root 'publish'
$buildScript = Join-Path $root 'Build-Release.ps1'
$portableSource = Join-Path $root 'dist\Dota2MapSwitcher-Portable.zip'
$portableExeSource = Join-Path $root 'dist\Dota2MapSwitcher-Portable\Dota2MapSwitcher.exe'
$setupSource = Join-Path $root 'dist\Dota2MapSwitcherSetup.exe'
if ([string]::IsNullOrWhiteSpace($NotesFile)) {
    $NotesFile = Join-Path $root 'RELEASE-NOTES.md'
}

function Assert-SemanticVersion {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        throw "版本号必须是 major.minor.patch 格式，例如 1.1.6。当前值：$Value"
    }
    return [pscustomobject]@{
        Major = [int]$Matches.major
        Minor = [int]$Matches.minor
        Patch = [int]$Matches.patch
    }
}

function Invoke-CheckedNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "命令执行失败（退出码 $LASTEXITCODE）：$FilePath $($ArgumentList -join ' ')"
    }
}

if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "找不到版本文件：$versionFile"
}
if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
    throw "找不到更新说明：$NotesFile"
}

$currentVersion = [System.IO.File]::ReadAllText($versionFile, [System.Text.Encoding]::UTF8).Trim()
$currentParts = Assert-SemanticVersion $currentVersion
if (-not [string]::IsNullOrWhiteSpace($Version) -and $Bump -ne 'None') {
    throw '-Version 和 -Bump 不能同时使用。'
}

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    [void](Assert-SemanticVersion $Version)
    $targetVersion = $Version
} elseif ($Bump -ne 'None') {
    $major = $currentParts.Major
    $minor = $currentParts.Minor
    $patch = $currentParts.Patch
    switch ($Bump) {
        'Patch' { $patch++ }
        'Minor' { $minor++; $patch = 0 }
        'Major' { $major++; $minor = 0; $patch = 0 }
    }
    $targetVersion = "$major.$minor.$patch"
} else {
    $targetVersion = $currentVersion
}
$tag = 'v' + $targetVersion

if ($PublishGitHub) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw '未安装 Git，无法发布 GitHub Release。'
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw '未安装 GitHub CLI（gh），无法发布 GitHub Release。'
    }
    $gitStatus = @(& git -C $root status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 状态。' }
    if ($gitStatus.Count -gt 0) {
        throw "发布 GitHub Release 前必须先提交所有改动。`r`n$($gitStatus -join "`r`n")"
    }
    $authOutput = @(& gh auth status 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI 尚未正常登录。请先运行 gh auth login。`r`n$($authOutput -join "`r`n")"
    }
    $branch = (& git -C $root branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw '当前不在有效的 Git 分支上。'
    }
    $originUrl = (& git -C $root remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) {
        throw '未配置 Git 远程 origin。'
    }
    if ($Bump -eq 'None' -and $targetVersion -ne $currentVersion) {
        throw "GitHub 发布版本 $targetVersion 与 VERSION 中的 $currentVersion 不一致。"
    }
}

if ($Bump -ne 'None') {
    [System.IO.File]::WriteAllText($versionFile, $targetVersion + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[VERSION] $currentVersion -> $targetVersion" -ForegroundColor Cyan
}

if (-not $SkipBuild) {
    Write-Host "== 构建 v$targetVersion ==" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -Version $targetVersion
    if ($LASTEXITCODE -ne 0) { throw '发布构建失败。' }
}

foreach ($requiredPath in @($portableSource, $portableExeSource, $setupSource)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "发布产物不存在：$requiredPath"
    }
}

$expectedFileVersion = $targetVersion + '.0'
foreach ($executablePath in @($portableExeSource, $setupSource)) {
    $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath).FileVersion
    if ($fileVersion -ne $expectedFileVersion) {
        throw "成品版本校验失败：$executablePath 实际为 $fileVersion，期望为 $expectedFileVersion。"
    }
}

$publishRootFull = [System.IO.Path]::GetFullPath($publishRoot)
$releaseDirectory = [System.IO.Path]::GetFullPath((Join-Path $publishRootFull $tag))
$expectedPrefix = $publishRootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $releaseDirectory.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "发布目录超出 publish 范围：$releaseDirectory"
}
if (Test-Path -LiteralPath $releaseDirectory) {
    Remove-Item -LiteralPath $releaseDirectory -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $releaseDirectory -Force)

$portableAsset = Join-Path $releaseDirectory "Dota2MapSwitcher-$tag-Portable.zip"
$setupAsset = Join-Path $releaseDirectory "Dota2MapSwitcher-$tag-Setup.exe"
$quarkNotesPath = Join-Path $releaseDirectory '更新说明.txt'
$checksumsPath = Join-Path $releaseDirectory 'SHA256SUMS.txt'
Copy-Item -LiteralPath $portableSource -Destination $portableAsset
Copy-Item -LiteralPath $setupSource -Destination $setupAsset

$notes = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $NotesFile), [System.Text.Encoding]::UTF8).Trim()
$quarkNotes = "Dota 2 地图更换器 $tag`r`n发布日期：$((Get-Date).ToString('yyyy-MM-dd'))`r`n`r`n$notes`r`n"
[System.IO.File]::WriteAllText($quarkNotesPath, $quarkNotes, (New-Object System.Text.UTF8Encoding($true)))

$hashLines = foreach ($asset in @($portableAsset, $setupAsset)) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $asset
    '{0}  {1}' -f $hash.Hash, [System.IO.Path]::GetFileName($asset)
}
[System.IO.File]::WriteAllLines($checksumsPath, $hashLines, (New-Object System.Text.UTF8Encoding($false)))

if ($PublishGitHub) {
    if ($Bump -ne 'None') {
        Invoke-CheckedNativeCommand git @('-C', $root, 'add', '--', 'VERSION')
        Invoke-CheckedNativeCommand git @('-C', $root, 'commit', '-m', "发布 $tag")
    }

    $headCommit = (& git -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw '无法读取当前 Git 提交。' }
    $existingTag = (& git -C $root tag --list $tag).Trim()
    if ([string]::IsNullOrWhiteSpace($existingTag)) {
        Invoke-CheckedNativeCommand git @('-C', $root, 'tag', '-a', $tag, '-m', "Dota 2 地图更换器 $tag")
    } else {
        $tagCommit = (& git -C $root rev-list -n 1 $tag).Trim()
        if ($LASTEXITCODE -ne 0 -or $tagCommit -ne $headCommit) {
            throw "标签 $tag 已存在，但不指向当前提交。"
        }
    }

    $branch = (& git -C $root branch --show-current).Trim()
    Invoke-CheckedNativeCommand git @('-C', $root, 'push', 'origin', $branch)
    Invoke-CheckedNativeCommand git @('-C', $root, 'push', 'origin', $tag)

    $releaseCheck = @(& gh release view $tag --json tagName 2>&1)
    if ($LASTEXITCODE -eq 0) {
        throw "GitHub Release $tag 已经存在，为避免覆盖已发布文件，脚本已停止。"
    }
    Invoke-CheckedNativeCommand gh @(
        'release', 'create', $tag,
        $portableAsset,
        $setupAsset,
        $checksumsPath,
        '--title', "Dota 2 地图更换器 $tag",
        '--notes-file', (Resolve-Path -LiteralPath $NotesFile).Path,
        '--verify-tag',
        '--latest'
    )
}

Write-Host ''
Write-Host "== 发布包已就绪：$tag ==" -ForegroundColor Green
Write-Host $releaseDirectory
Write-Host ([System.IO.Path]::GetFileName($portableAsset))
Write-Host ([System.IO.Path]::GetFileName($setupAsset))
Write-Host ([System.IO.Path]::GetFileName($checksumsPath))
if (-not $PublishGitHub) {
    Write-Host '未执行 GitHub 发布；可将上述目录直接上传到夸克。' -ForegroundColor Yellow
}
