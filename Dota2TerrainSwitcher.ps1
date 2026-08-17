[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$UiSmokeTest,
    [switch]$UiCloseTest,
    [switch]$UiCrashRecoveryTest,
    [switch]$RestoreAndExit,
    [string]$UiSnapshotPath,
    [string]$StateFileOverridePath,
    [string]$AppDirectoryOverride,
    [string]$ResourceDirectoryOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppDirectory = if ([string]::IsNullOrWhiteSpace($AppDirectoryOverride)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.IO.Path]::GetFullPath($AppDirectoryOverride)
}
$script:ResourceDirectory = if ([string]::IsNullOrWhiteSpace($ResourceDirectoryOverride)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.IO.Path]::GetFullPath($ResourceDirectoryOverride)
}
$script:CatalogPath = Join-Path $script:ResourceDirectory 'terrain-catalog.json'
$script:UiTextPath = Join-Path $script:ResourceDirectory 'ui.zh-CN.json'
$script:IconPath = Join-Path $script:ResourceDirectory 'Dota2TerrainSwitcher.ico'
if (-not (Test-Path -LiteralPath $script:IconPath -PathType Leaf)) {
    $script:IconPath = Join-Path $script:ResourceDirectory 'assets\Dota2TerrainSwitcher.ico'
}
$script:LegacyBackupRoot = Join-Path $script:AppDirectory 'backups'
$script:LegacyStatePath = Join-Path $script:AppDirectory 'active-swap.json'
$script:StateRegistryPath = 'HKCU:\Software\Dota2TerrainSwitcher'
$script:StateFileOverride = if ([string]::IsNullOrWhiteSpace($StateFileOverridePath)) { $null } else { [System.IO.Path]::GetFullPath($StateFileOverridePath) }
$script:PreferencesPath = if (-not [string]::IsNullOrWhiteSpace($script:StateFileOverride)) {
    Join-Path (Split-Path -Parent $script:StateFileOverride) 'preferences.json'
} else {
    Join-Path (Join-Path $script:AppDirectory '.data') 'preferences.json'
}

function Read-TerrainCatalog {
    if (-not (Test-Path -LiteralPath $script:CatalogPath -PathType Leaf)) {
        throw "Catalog file is missing: $script:CatalogPath"
    }

    $json = [System.IO.File]::ReadAllText($script:CatalogPath, [System.Text.Encoding]::UTF8)
    return @($json | ConvertFrom-Json)
}

function Read-UiText {
    if (-not (Test-Path -LiteralPath $script:UiTextPath -PathType Leaf)) {
        throw "UI text file is missing: $script:UiTextPath"
    }
    $json = [System.IO.File]::ReadAllText($script:UiTextPath, [System.Text.Encoding]::UTF8)
    return $json | ConvertFrom-Json
}

# Steam can retain library entries for a drive that is no longer connected.
# Do not pass those paths to Join-Path/Test-Path: with ErrorActionPreference=Stop,
# PowerShell turns the "drive does not exist" error into a startup failure.
function Test-AvailableDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        return [System.IO.Directory]::Exists($Path.Trim().Trim('"'))
    } catch {
        return $false
    }
}

function Get-ActiveSwapState {
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:StateFileOverride)) {
            if (-not (Test-Path -LiteralPath $script:StateFileOverride -PathType Leaf)) { return $null }
            $state = [System.IO.File]::ReadAllText($script:StateFileOverride, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        } else {
            if (-not (Test-Path -LiteralPath $script:StateRegistryPath)) { return $null }
            $saved = Get-ItemProperty -LiteralPath $script:StateRegistryPath
            $state = [pscustomobject]@{
                version       = [int]$saved.version
                status        = [string]$saved.status
                createdAt     = [string]$saved.createdAt
                mapsDirectory = [string]$saved.mapsDirectory
                ownedFile     = [string]$saved.ownedFile
                ownedName     = [string]$saved.ownedName
                targetFile    = [string]$saved.targetFile
                targetName    = [string]$saved.targetName
            }
        }
        foreach ($property in @('mapsDirectory','ownedFile','targetFile','status')) {
            if (-not ($state.PSObject.Properties.Name -contains $property) -or [string]::IsNullOrWhiteSpace([string]$state.$property)) {
                throw "Missing state property: $property"
            }
        }
        return $state
    } catch {
        throw "The active swap state is invalid. $($_.Exception.Message)"
    }
}

function Write-ActiveSwapState {
    param([Parameter(Mandatory)]$State)
    if (-not [string]::IsNullOrWhiteSpace($script:StateFileOverride)) {
        $stateDirectory = Split-Path -Parent $script:StateFileOverride
        if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
        }
        if ((Split-Path -Leaf $stateDirectory) -eq '.data') {
            try {
                $stateDirectoryItem = Get-Item -LiteralPath $stateDirectory -Force
                $stateDirectoryItem.Attributes = $stateDirectoryItem.Attributes -bor [System.IO.FileAttributes]::Hidden
            } catch { }
        }
        $temporary = $script:StateFileOverride + '.tmp'
        [System.IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $script:StateFileOverride -Force
        return
    }
    if (-not (Test-Path -LiteralPath $script:StateRegistryPath)) {
        [void](New-Item -Path $script:StateRegistryPath -Force)
    }
    foreach ($name in @('version','status','createdAt','mapsDirectory','ownedFile','ownedName','targetFile','targetName')) {
        $value = if ($State -is [System.Collections.IDictionary] -and $State.Contains($name)) {
            [string]$State[$name]
        } elseif ($State.PSObject.Properties.Name -contains $name) {
            [string]$State.PSObject.Properties[$name].Value
        } else {
            ''
        }
        Set-ItemProperty -LiteralPath $script:StateRegistryPath -Name $name -Value $value
    }
}

function Clear-ActiveSwapState {
    if (-not [string]::IsNullOrWhiteSpace($script:StateFileOverride)) {
        if (Test-Path -LiteralPath $script:StateFileOverride -PathType Leaf) {
            Remove-Item -LiteralPath $script:StateFileOverride -Force
        }
        $temporary = $script:StateFileOverride + '.tmp'
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
        $stateDirectory = Split-Path -Parent $script:StateFileOverride
        if ((Test-Path -LiteralPath $stateDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $stateDirectory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $stateDirectory -Force
        }
        return
    }
    if (Test-Path -LiteralPath $script:StateRegistryPath) {
        Remove-Item -LiteralPath $script:StateRegistryPath -Recurse -Force
    }
}

function Get-SelectionPreferences {
    if (-not (Test-Path -LiteralPath $script:PreferencesPath -PathType Leaf)) { return $null }
    try {
        $preferences = [System.IO.File]::ReadAllText($script:PreferencesPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not ($preferences.PSObject.Properties.Name -contains 'ownedFile') -or [string]::IsNullOrWhiteSpace([string]$preferences.ownedFile)) {
            throw 'Missing preference property: ownedFile'
        }
        return $preferences
    } catch {
        throw "The saved selection is invalid. $($_.Exception.Message)"
    }
}

function Write-SelectionPreferences {
    param(
        [string]$OwnedFile,
        [string]$TargetFile,
        [string]$MapsDirectory
    )
    $dataDirectory = Split-Path -Parent $script:PreferencesPath
    if ([string]::IsNullOrWhiteSpace($OwnedFile)) {
        if (Test-Path -LiteralPath $script:PreferencesPath -PathType Leaf) {
            Remove-Item -LiteralPath $script:PreferencesPath -Force
        }
        $temporary = $script:PreferencesPath + '.tmp'
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
        if ((Test-Path -LiteralPath $dataDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $dataDirectory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $dataDirectory -Force
        }
        return
    }

    if (-not (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $dataDirectory -Force)
    }
    try {
        $dataDirectoryItem = Get-Item -LiteralPath $dataDirectory -Force
        $dataDirectoryItem.Attributes = $dataDirectoryItem.Attributes -bor [System.IO.FileAttributes]::Hidden
    } catch { }
    $preferences = [ordered]@{
        version    = 1
        updatedAt  = (Get-Date).ToString('o')
        ownedFile  = $OwnedFile
        targetFile = if ([string]::IsNullOrWhiteSpace($TargetFile)) { $null } else { $TargetFile }
        mapsDirectory = if ([string]::IsNullOrWhiteSpace($MapsDirectory)) { $null } else { [System.IO.Path]::GetFullPath($MapsDirectory) }
    }
    $temporary = $script:PreferencesPath + '.tmp'
    [System.IO.File]::WriteAllText($temporary, ($preferences | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $script:PreferencesPath -Force
}

function Import-RegistryActiveSwapState {
    if ([string]::IsNullOrWhiteSpace($script:StateFileOverride)) { return }
    if (-not (Test-Path -LiteralPath $script:StateRegistryPath)) { return }
    $saved = Get-ItemProperty -LiteralPath $script:StateRegistryPath
    $registryState = [ordered]@{
        version       = [int]$saved.version
        status        = [string]$saved.status
        createdAt     = [string]$saved.createdAt
        mapsDirectory = [string]$saved.mapsDirectory
        ownedFile     = [string]$saved.ownedFile
        ownedName     = [string]$saved.ownedName
        targetFile    = [string]$saved.targetFile
        targetName    = [string]$saved.targetName
    }
    foreach ($property in @('mapsDirectory','ownedFile','targetFile','status')) {
        if ([string]::IsNullOrWhiteSpace([string]$registryState[$property])) { throw "Registry state is missing: $property" }
    }
    if (-not (Test-AvailableDirectory $registryState.mapsDirectory)) {
        # Registry state belongs to a previous local installation.  It cannot
        # describe a usable swap when its drive is no longer present.
        Remove-Item -LiteralPath $script:StateRegistryPath -Recurse -Force
        return
    }
    if (Test-Path -LiteralPath $script:StateFileOverride -PathType Leaf) {
        $portableState = Get-ActiveSwapState
        if ($portableState.mapsDirectory -ne $registryState.mapsDirectory -or $portableState.ownedFile -ne $registryState.ownedFile -or $portableState.targetFile -ne $registryState.targetFile) {
            throw 'Portable and registry swap states conflict.'
        }
    } else {
        Write-ActiveSwapState $registryState
    }
    Remove-Item -LiteralPath $script:StateRegistryPath -Recurse -Force
}

function Import-LegacyActiveSwapState {
    if (Get-ActiveSwapState) { return }
    if (-not (Test-Path -LiteralPath $script:LegacyStatePath -PathType Leaf)) { return }
    $legacy = [System.IO.File]::ReadAllText($script:LegacyStatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($property in @('mapsDirectory','ownedFile','targetFile','status')) {
        if (-not ($legacy.PSObject.Properties.Name -contains $property) -or [string]::IsNullOrWhiteSpace([string]$legacy.$property)) {
            throw "Legacy state is missing: $property"
        }
    }
    # A portable folder may have been copied from another computer.  Keep an
    # unreachable legacy record untouched instead of making the new computer
    # fail to launch (for example, when the old computer used H:\).
    if (-not (Test-AvailableDirectory ([string]$legacy.mapsDirectory))) { return }
    $state = [ordered]@{
        version       = 2
        status        = [string]$legacy.status
        createdAt     = if ($legacy.PSObject.Properties.Name -contains 'createdAt') { [string]$legacy.createdAt } else { (Get-Date).ToString('o') }
        mapsDirectory = [System.IO.Path]::GetFullPath([string]$legacy.mapsDirectory)
        ownedFile     = [string]$legacy.ownedFile
        ownedName     = if ($legacy.PSObject.Properties.Name -contains 'ownedName') { [string]$legacy.ownedName } else { [string]$legacy.ownedFile }
        targetFile    = [string]$legacy.targetFile
        targetName    = if ($legacy.PSObject.Properties.Name -contains 'targetName') { [string]$legacy.targetName } else { [string]$legacy.targetFile }
    }
    if (-not (Test-VpkFile (Join-Path $state.mapsDirectory $state.ownedFile)) -or -not (Test-VpkFile (Join-Path $state.mapsDirectory $state.targetFile))) {
        throw 'Legacy active swap files are missing or invalid; the old backup was preserved.'
    }
    Write-ActiveSwapState $state
    if ($legacy.PSObject.Properties.Name -contains 'backupDirectory' -and -not [string]::IsNullOrWhiteSpace([string]$legacy.backupDirectory)) {
        $backupPath = [System.IO.Path]::GetFullPath([string]$legacy.backupDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $backupRoot = [System.IO.Path]::GetFullPath($script:LegacyBackupRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if ((Split-Path $backupPath -Parent) -ne $backupRoot) { throw "Legacy backup escaped the expected directory: $backupPath" }
        if (Test-Path -LiteralPath $backupPath -PathType Container) { Remove-Item -LiteralPath $backupPath -Recurse -Force }
    }
    Remove-Item -LiteralPath $script:LegacyStatePath -Force
    if (Test-Path -LiteralPath $script:LegacyBackupRoot -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $script:LegacyBackupRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $script:LegacyBackupRoot -Force
        }
    }
}

function Resolve-DotaRoot {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { $fullPath = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"')) } catch { return $null }
    if (-not (Test-AvailableDirectory $fullPath)) { return $null }

    $candidates = @(
        $fullPath,
        (Join-Path $fullPath 'dota 2 beta'),
        (Split-Path (Split-Path (Split-Path $fullPath -Parent) -Parent) -Parent)
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $maps = Join-Path $candidate 'game\dota\maps'
        if (Test-Path -LiteralPath (Join-Path $maps 'dota.vpk') -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    # Also accept the game, dota, or maps directory itself.
    $cursor = $fullPath
    for ($i = 0; $i -lt 4; $i++) {
        if ((Split-Path $cursor -Leaf) -ieq 'dota 2 beta') {
            $maps = Join-Path $cursor 'game\dota\maps'
            if (Test-Path -LiteralPath (Join-Path $maps 'dota.vpk') -PathType Leaf) { return $cursor }
        }
        $parent = Split-Path $cursor -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $null
}

function Get-SteamLibraryRoots {
    $steamRoots = [System.Collections.Generic.List[string]]::new()
    $registryKeys = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\Software\Valve\Steam',
        'HKLM:\Software\WOW6432Node\Valve\Steam'
    )

    foreach ($key in $registryKeys) {
        try {
            $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).InstallPath
            if ($value) { $steamRoots.Add([string]$value) }
        } catch { }
    }

    if (${env:ProgramFiles(x86)}) { $steamRoots.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if ($env:ProgramFiles) { $steamRoots.Add((Join-Path $env:ProgramFiles 'Steam')) }

    $libraries = [System.Collections.Generic.List[string]]::new()
    foreach ($steamRoot in @($steamRoots | Select-Object -Unique)) {
        if (-not (Test-AvailableDirectory $steamRoot)) { continue }
        $libraries.Add($steamRoot)
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        try {
            $content = [System.IO.File]::ReadAllText($vdf)
            foreach ($match in [regex]::Matches($content, '"path"\s*"([^"\r\n]+)"')) {
                $library = $match.Groups[1].Value -replace '\\\\', '\'
                if (Test-AvailableDirectory $library) { $libraries.Add($library) }
            }
        } catch { }
    }
    return @($libraries | Select-Object -Unique)
}

function Find-DotaInstallations {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($library in Get-SteamLibraryRoots) {
        if (-not (Test-AvailableDirectory $library)) { continue }
        $steamApps = Join-Path $library 'steamapps'
        $manifest = Join-Path $steamApps 'appmanifest_570.acf'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            try {
                $content = [System.IO.File]::ReadAllText($manifest)
                $match = [regex]::Match($content, '"installdir"\s*"([^"\r\n]+)"')
                if ($match.Success) {
                    $candidate = Join-Path (Join-Path $steamApps 'common') $match.Groups[1].Value
                    $resolved = Resolve-DotaRoot $candidate
                    if ($resolved) { $found.Add($resolved) }
                }
            } catch { }
        }

        $fallback = Resolve-DotaRoot (Join-Path $steamApps 'common\dota 2 beta')
        if ($fallback) { $found.Add($fallback) }
    }
    return @($found | Select-Object -Unique)
}

function Get-MapsDirectory {
    param([Parameter(Mandatory)][string]$DotaRoot)
    return Join-Path $DotaRoot 'game\dota\maps'
}

function Test-VpkFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            if ($stream.Length -lt 4) { return $false }
            $bytes = New-Object byte[] 4
            [void]$stream.Read($bytes, 0, 4)
            return [BitConverter]::ToUInt32($bytes, 0) -eq [uint32]0x55AA1234
        } finally { $stream.Dispose() }
    } catch { return $false }
}

function Invoke-TerrainSwap {
    param(
        [Parameter(Mandatory)][string]$MapsDirectory,
        [Parameter(Mandatory)][string]$OwnedFile,
        [Parameter(Mandatory)][string]$TargetFile
    )

    if ($OwnedFile -eq $TargetFile) { throw 'The two terrain files must be different.' }
    $ownedPath = Join-Path $MapsDirectory $OwnedFile
    $targetPath = Join-Path $MapsDirectory $TargetFile
    if (-not (Test-VpkFile $ownedPath)) { throw "Invalid or missing VPK: $ownedPath" }
    if (-not (Test-VpkFile $targetPath)) { throw "Invalid or missing VPK: $targetPath" }

    $temporary = Join-Path $MapsDirectory ('.terrain_switcher_' + [guid]::NewGuid().ToString('N') + '.vpk')
    $stage = 0
    try {
        Move-Item -LiteralPath $ownedPath -Destination $temporary
        $stage = 1
        Move-Item -LiteralPath $targetPath -Destination $ownedPath
        $stage = 2
        Move-Item -LiteralPath $temporary -Destination $targetPath
        $stage = 3
    } catch {
        $problem = $_
        try {
            if ($stage -eq 2) {
                Move-Item -LiteralPath $ownedPath -Destination $targetPath
                Move-Item -LiteralPath $temporary -Destination $ownedPath
            } elseif ($stage -eq 1) {
                Move-Item -LiteralPath $temporary -Destination $ownedPath
            }
        } catch { }
        throw $problem
    }
}

function Restore-ActiveSwap {
    $state = Get-ActiveSwapState
    if (-not $state) { return $null }
    [void](Invoke-TerrainSwap -MapsDirectory $state.mapsDirectory -OwnedFile $state.ownedFile -TargetFile $state.targetFile)
    Clear-ActiveSwapState
    return $state
}

function Invoke-ManagedTerrainSwitch {
    param(
        [Parameter(Mandatory)][string]$MapsDirectory,
        [Parameter(Mandatory)][string]$OwnedFile,
        [Parameter(Mandatory)][string]$TargetFile,
        [Parameter(Mandatory)][string]$OwnedName,
        [Parameter(Mandatory)][string]$TargetName
    )

    if ($OwnedFile -eq $TargetFile) { throw 'The two terrain files must be different.' }
    $previousState = Restore-ActiveSwap
    $state = [ordered]@{
        version       = 2
        status        = 'pending'
        createdAt     = (Get-Date).ToString('o')
        mapsDirectory = [System.IO.Path]::GetFullPath($MapsDirectory)
        ownedFile     = $OwnedFile
        ownedName     = $OwnedName
        targetFile    = $TargetFile
        targetName    = $TargetName
    }

    Write-ActiveSwapState $state
    try {
        [void](Invoke-TerrainSwap -MapsDirectory $MapsDirectory -OwnedFile $OwnedFile -TargetFile $TargetFile)
        $state.status = 'active'
        Write-ActiveSwapState $state
    } catch {
        $problem = $_
        try { Clear-ActiveSwapState } catch { }
        throw $problem
    }

    return [pscustomobject]@{
        PreviousSwap = $previousState
        State        = Get-ActiveSwapState
    }
}

function Write-TestVpk {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte]$Marker)
    $bytes = New-Object byte[] 12
    [BitConverter]::GetBytes([uint32]0x55AA1234).CopyTo($bytes, 0)
    for ($i = 4; $i -lt $bytes.Length; $i++) { $bytes[$i] = $Marker }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-SelfTest {
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('Dota2TerrainSwitcher_' + [guid]::NewGuid().ToString('N'))
    $maps = Join-Path $testRoot 'game\dota\maps'
    [void](New-Item -ItemType Directory -Path $maps -Force)
    $oldStateFileOverride = $script:StateFileOverride
    $script:StateFileOverride = Join-Path $testRoot 'active-swap.json'
    try {
        $expectedCatalog = [ordered]@{
            divine        = 'dota_ti10.vpk|dota_ti10.png'
            journey       = 'dota_journey.vpk|dota_journey.png'
            overgrown     = 'dota_jungle.vpk|dota_jungle.png'
            summer        = 'dota_summer.vpk|dota_summer.png'
            emerald_abyss = 'dota_reef.vpk|dota_cavern.png'
            spring        = 'dota_spring.vpk|dota_spring.png'
            reefs_edge    = 'dota_cavern.vpk|dota_reef.png'
            autumn        = 'dota_autumn.vpk|dota_autumn.png'
            immortal      = 'dota_coloseum.vpk|dota_coloseum.png'
            winter        = 'dota_winter.vpk|dota_winter.png'
            desert        = 'dota_desert.vpk|dota_desert.png'
        }
        $catalog = Read-TerrainCatalog
        if ($catalog.Count -ne $expectedCatalog.Count) { throw 'Terrain catalog count test failed.' }
        foreach ($terrain in $catalog) {
            $actualMapping = ([string]$terrain.file) + '|' + ([string]$terrain.image)
            if (-not $expectedCatalog.Contains([string]$terrain.id) -or $expectedCatalog[[string]$terrain.id] -ne $actualMapping) {
                throw "Terrain catalog mapping test failed: $($terrain.id) / $actualMapping"
            }
            if ([string]::IsNullOrWhiteSpace([string]$terrain.zh)) { throw "Terrain name is missing: $($terrain.id)" }
        }
        Write-TestVpk (Join-Path $maps 'dota.vpk') 1
        Write-TestVpk (Join-Path $maps 'dota_ti10.vpk') 2
        Write-TestVpk (Join-Path $maps 'dota_desert.vpk') 3
        $resolved = Resolve-DotaRoot $testRoot
        if ($resolved -ne $testRoot) { throw 'Resolve-DotaRoot test failed.' }
        $missingDrive = @([char[]](68..90 | ForEach-Object { [char]$_ }) | Where-Object {
            -not [System.IO.Directory]::Exists(([string]$_) + ':\\')
        }) | Select-Object -First 1
        if ($missingDrive -and (Resolve-DotaRoot (([string]$missingDrive) + ':\\steamapps\\common\\dota 2 beta'))) {
            throw 'Unavailable drive path safety test failed.'
        }
        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $maps -OwnedFile 'dota_ti10.vpk' -TargetFile 'dota.vpk' -OwnedName 'TI10' -TargetName 'Default')
        if ([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk'))[4] -ne 1) { throw 'First managed swap test failed.' }
        if (-not (Test-Path -LiteralPath $script:StateFileOverride -PathType Leaf)) { throw 'Persistent state test failed.' }

        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $maps -OwnedFile 'dota_ti10.vpk' -TargetFile 'dota_desert.vpk' -OwnedName 'TI10' -TargetName 'Desert')
        if ([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota.vpk'))[4] -ne 1) { throw 'Automatic previous restore test failed.' }
        if ([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk'))[4] -ne 3) { throw 'Second managed swap test failed.' }
        if ([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_desert.vpk'))[4] -ne 2) { throw 'Second target content test failed.' }

        $persisted = Get-ActiveSwapState
        if ($persisted.targetFile -ne 'dota_desert.vpk' -or $persisted.status -ne 'active') { throw 'Saved file information test failed.' }
        [void](Restore-ActiveSwap)
        if ([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk'))[4] -ne 2) { throw 'Final recovery test failed.' }
        if (Test-Path -LiteralPath $script:StateFileOverride) { throw 'State cleanup test failed.' }
        if (@(Get-ChildItem -LiteralPath $maps -Filter '.terrain_switcher_*.vpk').Count -ne 0) { throw 'Temporary file cleanup test failed.' }
        if (Test-Path -LiteralPath (Join-Path $testRoot 'backups')) { throw 'Unexpected backup directory test failed.' }
        Write-Output 'SELF-TEST PASSED'
    } finally {
        $script:StateFileOverride = $oldStateFileOverride
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if (-not $UiSmokeTest -and [string]::IsNullOrWhiteSpace($UiSnapshotPath) -and -not $UiCloseTest -and -not $UiCrashRecoveryTest) {
    Import-RegistryActiveSwapState
    Import-LegacyActiveSwapState
}

if ($RestoreAndExit) {
    try {
        $activeState = Get-ActiveSwapState
        if ($activeState) {
            if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) {
                throw '请先完全退出 Dota 2，再卸载本工具。'
            }
            [void](Restore-ActiveSwap)
        }
        return
    } catch {
        throw ('卸载前无法恢复地图：' + $_.Exception.Message)
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Dota 2" Width="1040" Height="790" MinWidth="1000" MinHeight="650" WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip" Background="#0B1117" Foreground="#F3F4F6" FontFamily="Microsoft YaHei UI">
  <Grid Margin="14,12,14,14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="7,0,7,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Name="TitleText" Text="Dota 2" FontSize="24" FontWeight="SemiBold" Foreground="#F3F4F6" VerticalAlignment="Center"/>
      <Button Grid.Column="1" Name="HelpButton" Content="?" Width="30" Height="30" Padding="0" Margin="0" FontSize="17" FontWeight="SemiBold" Foreground="#D7DCE1" Background="#1B2731" BorderBrush="#536473" BorderThickness="1" Cursor="Hand"/>
    </Grid>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="#0B1117">
      <WrapPanel Name="TerrainPanel" Width="984" HorizontalAlignment="Center" VerticalAlignment="Top"/>
    </ScrollViewer>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
if (Test-Path -LiteralPath $script:IconPath -PathType Leaf) {
    try {
        $iconStream = [System.IO.File]::OpenRead($script:IconPath)
        try {
            $iconDecoder = [Windows.Media.Imaging.BitmapDecoder]::Create(
                $iconStream,
                [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $window.Icon = $iconDecoder.Frames[0]
            if ($window.Icon.CanFreeze) { $window.Icon.Freeze() }
        } finally {
            $iconStream.Dispose()
        }
    } catch { }
}
$uiNames = @('TitleText','HelpButton','TerrainPanel')
$ui = @{}
foreach ($name in $uiNames) { $ui[$name] = $window.FindName($name) }

$text = Read-UiText
$window.Title = $text.windowTitle
$ui.TitleText.Text = $text.windowTitle

$script:Catalog = Read-TerrainCatalog
$script:CatalogLookup = @{}
$script:CardLookup = @{}
$script:CurrentMaps = $null
$script:SelectedOwnedFile = $null
$script:SelectedTargetFile = $null
$script:IsBusy = $false
$script:AllowWindowClose = $false
$script:TerrainImageDirectory = Join-Path $script:ResourceDirectory 'terrains'
if (-not (Test-Path -LiteralPath $script:TerrainImageDirectory -PathType Container)) {
    $script:TerrainImageDirectory = Join-Path $script:ResourceDirectory 'assets\terrains'
}

function Get-UiBrush([string]$Color) {
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Update-CardVisuals {
    foreach ($item in $script:CardLookup.Values) {
        $item.Card.BorderBrush = Get-UiBrush '#263440'
        $item.Card.BorderThickness = New-Object Windows.Thickness 1
        $item.Badge.Visibility = [Windows.Visibility]::Collapsed
        $item.BadgeText.Text = ''
        if ($item.File -eq $script:SelectedOwnedFile) {
            $item.Card.BorderBrush = Get-UiBrush '#D2A62C'
            $item.Card.BorderThickness = New-Object Windows.Thickness 3
            $item.Badge.Background = Get-UiBrush '#A87B1D'
            $item.BadgeText.Text = $text.ownedBadge
            $item.Badge.Visibility = [Windows.Visibility]::Visible
        } elseif ($item.File -eq $script:SelectedTargetFile) {
            $item.Card.BorderBrush = Get-UiBrush '#8B5CF6'
            $item.Card.BorderThickness = New-Object Windows.Thickness 3
            $item.Badge.Background = Get-UiBrush '#6D3BC0'
            $item.BadgeText.Text = $text.targetBadge
            $item.Badge.Visibility = [Windows.Visibility]::Visible
        }
    }
}

function Set-CardHover {
    param([Parameter(Mandatory)]$Card, [Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][bool]$Hovered)
    if ($FileName -eq $script:SelectedOwnedFile -or $FileName -eq $script:SelectedTargetFile) { return }
    $Card.BorderBrush = Get-UiBrush $(if ($Hovered) { '#60758A' } else { '#263440' })
    $Card.BorderThickness = New-Object Windows.Thickness $(if ($Hovered) { 2 } else { 1 })
}

function New-TerrainCard {
    param([Parameter(Mandatory)]$Terrain)
    $imageName = [string]$Terrain.image
    $imagePath = Join-Path $script:TerrainImageDirectory $imageName
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw "Missing terrain image: $imageName" }

    $card = New-Object Windows.Controls.Border
    $card.Width = 232
    $card.Height = 218
    $card.Margin = New-Object Windows.Thickness 7
    $card.Background = Get-UiBrush '#071016'
    $card.BorderBrush = Get-UiBrush '#263440'
    $card.BorderThickness = New-Object Windows.Thickness 1
    $card.CornerRadius = New-Object Windows.CornerRadius 1
    $card.Cursor = [Windows.Input.Cursors]::Hand
    $card.Tag = [string]$Terrain.file

    $grid = New-Object Windows.Controls.Grid
    foreach ($height in @(148, 39, 31)) {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = New-Object Windows.GridLength $height
        [void]$grid.RowDefinitions.Add($row)
    }

    $imageBorder = New-Object Windows.Controls.Border
    $imageBorder.Background = Get-UiBrush '#111820'
    $imageBorder.ClipToBounds = $true
    $image = New-Object Windows.Controls.Image
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.DecodePixelWidth = 456
    $bitmap.UriSource = New-Object Uri ([System.IO.Path]::GetFullPath($imagePath))
    $bitmap.EndInit()
    $bitmap.Freeze()
    $image.Source = $bitmap
    $image.Stretch = [Windows.Media.Stretch]::UniformToFill
    $imageBorder.Child = $image
    [Windows.Controls.Grid]::SetRow($imageBorder, 0)
    [void]$grid.Children.Add($imageBorder)

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = [string]$Terrain.zh
    $name.FontSize = 15
    $name.FontWeight = [Windows.FontWeights]::Normal
    $name.Foreground = Get-UiBrush '#D7DCE1'
    $name.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $name.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $name.TextAlignment = [Windows.TextAlignment]::Center
    $name.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    [Windows.Controls.Grid]::SetRow($name, 1)
    [void]$grid.Children.Add($name)

    $badge = New-Object Windows.Controls.Border
    $badge.Margin = New-Object Windows.Thickness 20, 1, 20, 5
    $badge.CornerRadius = New-Object Windows.CornerRadius 2
    $badge.Visibility = [Windows.Visibility]::Collapsed
    $badgeText = New-Object Windows.Controls.TextBlock
    $badgeText.Foreground = Get-UiBrush '#FFFFFF'
    $badgeText.FontSize = 14
    $badgeText.FontWeight = [Windows.FontWeights]::SemiBold
    $badgeText.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $badgeText.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $badge.Child = $badgeText
    [Windows.Controls.Grid]::SetRow($badge, 2)
    [void]$grid.Children.Add($badge)

    $card.Child = $grid
    $card.Add_MouseEnter({ param($sender, $eventArgs) Set-CardHover -Card $sender -FileName ([string]$sender.Tag) -Hovered $true })
    $card.Add_MouseLeave({ param($sender, $eventArgs) Set-CardHover -Card $sender -FileName ([string]$sender.Tag) -Hovered $false })
    $card.Add_MouseLeftButtonUp({ param($sender, $eventArgs) Invoke-TerrainCardClick -FileName ([string]$sender.Tag) })
    $script:CardLookup[[string]$Terrain.file] = [pscustomobject]@{ File = [string]$Terrain.file; Card = $card; Badge = $badge; BadgeText = $badgeText }
    [void]$ui.TerrainPanel.Children.Add($card)
}

function Show-OperationError([string]$Message) {
    [System.Windows.MessageBox]::Show($window, $Message, $text.operationFailedTitle, 'OK', 'Error') | Out-Null
}

$ui.HelpButton.Add_Click({
    [System.Windows.MessageBox]::Show($window, $text.helpText, $text.helpTitle, 'OK', 'Information') | Out-Null
})

function Set-MapsFromFolder([string]$Folder) {
    $root = Resolve-DotaRoot $Folder
    if (-not $root) { return $false }
    $script:CurrentMaps = Get-MapsDirectory $root
    return $true
}

function Request-DotaFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $text.browseDescription
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
    if (-not (Set-MapsFromFolder $dialog.SelectedPath)) {
        Show-OperationError $text.invalidInstall
        return $false
    }
    return $true
}

function Initialize-DotaInstallation {
    try {
        $state = Get-ActiveSwapState
        if ($state -and -not (Test-AvailableDirectory ([string]$state.mapsDirectory))) {
            # An app folder copied from another computer can contain a stale
            # active-state record.  It must not prevent Dota auto-discovery.
            Clear-ActiveSwapState
        } elseif ($state -and (Test-VpkFile (Join-Path $state.mapsDirectory 'dota.vpk'))) {
            $script:CurrentMaps = [System.IO.Path]::GetFullPath([string]$state.mapsDirectory)
            return $true
        }
    } catch {
        Show-OperationError ($text.stateInvalid -f $_.Exception.Message)
        return $false
    }
    try {
        $preferences = Get-SelectionPreferences
        if ($preferences -and ($preferences.PSObject.Properties.Name -contains 'mapsDirectory') -and
            -not [string]::IsNullOrWhiteSpace([string]$preferences.mapsDirectory) -and
            (Test-VpkFile (Join-Path ([string]$preferences.mapsDirectory) 'dota.vpk'))) {
            $script:CurrentMaps = [System.IO.Path]::GetFullPath([string]$preferences.mapsDirectory)
            return $true
        }
    } catch { }
    $installs = @(Find-DotaInstallations)
    if ($installs.Count -gt 0 -and (Set-MapsFromFolder $installs[0])) { return $true }
    return Request-DotaFolder
}

function Sync-SelectionFromState {
    param([switch]$KeepOwnedWhenEmpty)
    try {
        $state = Get-ActiveSwapState
        if ($state) {
            if (-not $script:CatalogLookup.ContainsKey([string]$state.ownedFile) -or -not $script:CatalogLookup.ContainsKey([string]$state.targetFile)) {
                throw 'The saved terrain is not available in the image catalog.'
            }
            $correctOwnedName = [string]$script:CatalogLookup[[string]$state.ownedFile].zh
            $correctTargetName = [string]$script:CatalogLookup[[string]$state.targetFile].zh
            if ([string]$state.ownedName -ne $correctOwnedName -or [string]$state.targetName -ne $correctTargetName) {
                $state.ownedName = $correctOwnedName
                $state.targetName = $correctTargetName
                Write-ActiveSwapState $state
            }
            $script:SelectedOwnedFile = [string]$state.ownedFile
            $script:SelectedTargetFile = [string]$state.targetFile
        } else {
            $script:SelectedTargetFile = $null
            if (-not $KeepOwnedWhenEmpty) { $script:SelectedOwnedFile = $null }
        }
        Update-CardVisuals
    } catch {
        Update-CardVisuals
        Show-OperationError ($text.stateInvalid -f $_.Exception.Message)
    }
}

function Invoke-CardRestore {
    if ($script:IsBusy) { return }
    $ownedBeforeRestore = $script:SelectedOwnedFile
    $script:IsBusy = $true
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) { throw $text.gameRunningRestore }
        [void](Restore-ActiveSwap)
        $script:SelectedOwnedFile = $ownedBeforeRestore
        $script:SelectedTargetFile = $null
        Write-SelectionPreferences -OwnedFile $script:SelectedOwnedFile -TargetFile $null -MapsDirectory $script:CurrentMaps
        Update-CardVisuals
    } catch {
        Sync-SelectionFromState -KeepOwnedWhenEmpty
        Show-OperationError $_.Exception.Message
    } finally {
        $window.Cursor = [Windows.Input.Cursors]::Arrow
        $script:IsBusy = $false
    }
}

function Invoke-CardSwap {
    if ($script:IsBusy) { return }
    $owned = $script:CatalogLookup[$script:SelectedOwnedFile]
    $target = $script:CatalogLookup[$script:SelectedTargetFile]
    if (-not $owned -or -not $target) { return }
    if (-not $script:CurrentMaps -and -not (Initialize-DotaInstallation)) {
        $script:SelectedTargetFile = $null
        Update-CardVisuals
        return
    }
    $script:IsBusy = $true
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) { throw $text.gameRunningSwap }
        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $script:CurrentMaps -OwnedFile $owned.file -TargetFile $target.file -OwnedName $owned.zh -TargetName $target.zh)
        Write-SelectionPreferences -OwnedFile $owned.file -TargetFile $target.file -MapsDirectory $script:CurrentMaps
        Sync-SelectionFromState
    } catch {
        Sync-SelectionFromState -KeepOwnedWhenEmpty
        Show-OperationError $_.Exception.Message
    } finally {
        $window.Cursor = [Windows.Input.Cursors]::Arrow
        $script:IsBusy = $false
    }
}

function Invoke-TerrainCardClick {
    param([Parameter(Mandatory)][string]$FileName)
    if ($script:IsBusy -or -not $script:CatalogLookup.ContainsKey($FileName)) { return }
    try { $active = Get-ActiveSwapState } catch {
        Show-OperationError ($text.stateInvalid -f $_.Exception.Message)
        return
    }

    if ($active) {
        $script:SelectedOwnedFile = [string]$active.ownedFile
        $script:SelectedTargetFile = [string]$active.targetFile
        if ($FileName -eq [string]$active.targetFile) {
            Invoke-CardRestore
            return
        }
        if ($FileName -eq [string]$active.ownedFile) { return }
        $script:SelectedTargetFile = $FileName
        Update-CardVisuals
        Invoke-CardSwap
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:SelectedOwnedFile)) {
        $script:SelectedOwnedFile = $FileName
        $script:SelectedTargetFile = $null
        Write-SelectionPreferences -OwnedFile $script:SelectedOwnedFile -TargetFile $null -MapsDirectory $script:CurrentMaps
        Update-CardVisuals
        return
    }
    if ($FileName -eq $script:SelectedOwnedFile) {
        $script:SelectedOwnedFile = $null
        $script:SelectedTargetFile = $null
        Write-SelectionPreferences -OwnedFile $null -TargetFile $null -MapsDirectory $null
        Update-CardVisuals
        return
    }
    $script:SelectedTargetFile = $FileName
    Update-CardVisuals
    Invoke-CardSwap
}

function Restore-RememberedSelection {
    param([switch]$AllowAutomaticTarget)
    try {
        $preferences = Get-SelectionPreferences
        if (-not $preferences) { return }
        $ownedFile = [string]$preferences.ownedFile
        if (-not $script:CatalogLookup.ContainsKey($ownedFile)) {
            Write-SelectionPreferences -OwnedFile $null -TargetFile $null -MapsDirectory $null
            return
        }
        $script:SelectedOwnedFile = $ownedFile
        $script:SelectedTargetFile = $null

        $targetFile = if ($preferences.PSObject.Properties.Name -contains 'targetFile') { [string]$preferences.targetFile } else { '' }
        if ([string]::IsNullOrWhiteSpace($targetFile)) {
            Update-CardVisuals
            return
        }
        if ($targetFile -eq $ownedFile -or -not $script:CatalogLookup.ContainsKey($targetFile)) {
            Write-SelectionPreferences -OwnedFile $ownedFile -TargetFile $null -MapsDirectory $script:CurrentMaps
            Update-CardVisuals
            return
        }
        if (-not $AllowAutomaticTarget -or -not $script:CurrentMaps -or (Get-Process -Name dota2 -ErrorAction SilentlyContinue)) {
            Update-CardVisuals
            return
        }

        $script:SelectedTargetFile = $targetFile
        Update-CardVisuals
        Invoke-CardSwap
        if (-not (Get-ActiveSwapState)) {
            $script:SelectedTargetFile = $null
            Write-SelectionPreferences -OwnedFile $ownedFile -TargetFile $null -MapsDirectory $script:CurrentMaps
            Update-CardVisuals
        }
    } catch {
        $script:SelectedTargetFile = $null
        Update-CardVisuals
        Show-OperationError ($text.stateInvalid -f $_.Exception.Message)
    }
}

foreach ($terrain in $script:Catalog) {
    $script:CatalogLookup[[string]$terrain.file] = $terrain
    New-TerrainCard -Terrain $terrain
}
Update-CardVisuals

if (-not [string]::IsNullOrWhiteSpace($UiSnapshotPath)) {
    $script:SelectedOwnedFile = 'dota_ti10.vpk'
    $script:SelectedTargetFile = 'dota_cavern.vpk'
    Update-CardVisuals
    $window.Show()
    $window.UpdateLayout()
    $width = [Math]::Max(1, [int][Math]::Ceiling($window.ActualWidth))
    $height = [Math]::Max(1, [int][Math]::Ceiling($window.ActualHeight))
    $render = New-Object Windows.Media.Imaging.RenderTargetBitmap $width, $height, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($window)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    [void]$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $stream = [System.IO.File]::Create([System.IO.Path]::GetFullPath($UiSnapshotPath))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $window.Close()
    Write-Output ('UI SNAPSHOT SAVED: ' + [System.IO.Path]::GetFullPath($UiSnapshotPath))
    return
}

if ($UiSmokeTest) {
    foreach ($name in $uiNames) {
        if (-not $ui[$name]) { throw ('Missing map control: ' + $name) }
    }
    if ($script:CardLookup.Count -ne 11) { throw "Expected 11 terrain cards, found $($script:CardLookup.Count)." }
    if ($window.FindName('SwapButton') -or $window.FindName('RestoreButton') -or $window.FindName('PathBox')) { throw 'Legacy controls are still visible.' }
    Write-Output ('UI SMOKE TEST PASSED: image cards=11; title=' + $window.Title)
    $window.Close()
    return
}

$script:RecoveredCrashState = $false
if (-not $UiCloseTest) {
    try {
        $leftoverState = Get-ActiveSwapState
        if ($leftoverState) {
            if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) {
                [System.Windows.MessageBox]::Show($text.crashRecoveryGameRunning, $text.crashRecoveryTitle, 'OK', 'Warning') | Out-Null
                return
            }
            [void](Restore-ActiveSwap)
            $script:RecoveredCrashState = $true
        }
    } catch {
        [System.Windows.MessageBox]::Show(($text.crashRecoveryFailed -f $_.Exception.Message), $text.crashRecoveryTitle, 'OK', 'Error') | Out-Null
        return
    }
}
if ($UiCrashRecoveryTest) { return }

$installationReady = [bool](Initialize-DotaInstallation)
Sync-SelectionFromState
if (-not (Get-ActiveSwapState)) {
    Restore-RememberedSelection -AllowAutomaticTarget:($installationReady -and -not $script:RecoveredCrashState)
}
$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:AllowWindowClose) { return }
    if ($script:IsBusy) {
        $eventArgs.Cancel = $true
        return
    }
    try {
        $state = Get-ActiveSwapState
        if (-not $state) {
            $script:AllowWindowClose = $true
            return
        }
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) {
            $eventArgs.Cancel = $true
            [System.Windows.MessageBox]::Show($window, $text.closeWhileGameRunning, $text.closeRestoreFailedTitle, 'OK', 'Warning') | Out-Null
            return
        }
        $script:IsBusy = $true
        $window.Cursor = [Windows.Input.Cursors]::Wait
        [void](Restore-ActiveSwap)
        $script:SelectedTargetFile = $null
        Update-CardVisuals
        $script:AllowWindowClose = $true
    } catch {
        $eventArgs.Cancel = $true
        Show-OperationError $_.Exception.Message
    } finally {
        $window.Cursor = [Windows.Input.Cursors]::Arrow
        $script:IsBusy = $false
    }
})
if ($UiCloseTest) {
    $window.Add_ContentRendered({ $window.Close() })
}
[void]$window.ShowDialog()
