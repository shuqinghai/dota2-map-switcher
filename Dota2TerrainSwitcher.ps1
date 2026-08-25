[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$UiSmokeTest,
    [switch]$UiCloseTest,
    [switch]$UiCrashRecoveryTest,
    [switch]$RestoreAndExit,
    [switch]$AutoLaunch,
    [string[]]$AutoCommand,
    [string]$UiSnapshotPath,
    [ValidateSet('Mode','Normal','NormalGuide','NormalExit','Auto','AutoGuide','AutoActivated','Error')][string]$UiSnapshotKind = 'Auto',
    [ValidateSet(96,120,144)][int]$UiSnapshotDpi = 96,
    [string]$StateFileOverridePath,
    [string]$AppDirectoryOverride,
    [string]$ResourceDirectoryOverride,
    [string]$ExecutablePathOverride,
    [string]$TerrainMutexNameOverride
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
$script:DataDirectory = Split-Path -Parent $script:PreferencesPath
$script:AutoModePath = Join-Path $script:DataDirectory 'auto-mode.json'
$script:UiSettingsPath = Join-Path $script:DataDirectory 'ui-settings.json'
$script:TerrainSessionPath = Join-Path $script:DataDirectory 'terrain-session.json'
$script:AutoLogPath = Join-Path $script:DataDirectory 'auto-launch.log'
$script:ExecutablePath = if ([string]::IsNullOrWhiteSpace($ExecutablePathOverride)) {
    try { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { '' }
} else {
    [System.IO.Path]::GetFullPath($ExecutablePathOverride)
}
$script:TerrainMutexName = if ([string]::IsNullOrWhiteSpace($TerrainMutexNameOverride)) {
    'Local\Dota2TerrainSwitcher.TerrainSession.v1'
} else {
    $TerrainMutexNameOverride
}
$script:TerrainMutex = $null
$script:TerrainMutexOwned = $false
$script:TerrainSessionId = $null
$script:CurrentSessionOwner = $null

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

function Initialize-DataDirectory {
    if (-not (Test-Path -LiteralPath $script:DataDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $script:DataDirectory -Force)
    }
    try {
        $item = Get-Item -LiteralPath $script:DataDirectory -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    } catch { }
}

function Write-JsonFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Initialize-DataDirectory
    $temporary = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-AutoModeConfig {
    $default = [pscustomobject]@{
        version      = 1
        enabled      = $false
        ownedTerrain = $null
        terrain      = $null
        mapsDirectory = $null
        launcherPath = $null
        updatedAt    = $null
    }
    if (-not (Test-Path -LiteralPath $script:AutoModePath -PathType Leaf)) { return $default }
    try {
        $saved = [System.IO.File]::ReadAllText($script:AutoModePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return [pscustomobject]@{
            version      = 1
            enabled      = if ($saved.PSObject.Properties.Name -contains 'enabled') { [bool]$saved.enabled } else { $false }
            ownedTerrain = if ($saved.PSObject.Properties.Name -contains 'ownedTerrain') { [string]$saved.ownedTerrain } else { $null }
            terrain      = if ($saved.PSObject.Properties.Name -contains 'terrain') { [string]$saved.terrain } else { $null }
            mapsDirectory = if ($saved.PSObject.Properties.Name -contains 'mapsDirectory') { [string]$saved.mapsDirectory } else { $null }
            launcherPath = if ($saved.PSObject.Properties.Name -contains 'launcherPath') { [string]$saved.launcherPath } else { $null }
            updatedAt    = if ($saved.PSObject.Properties.Name -contains 'updatedAt') { [string]$saved.updatedAt } else { $null }
        }
    } catch {
        throw "自动替换配置损坏：$($_.Exception.Message)"
    }
}

function Save-AutoModeConfig {
    param([Parameter(Mandatory)]$Config)
    $value = [ordered]@{
        version       = 1
        enabled       = [bool]$Config.enabled
        ownedTerrain  = if ([string]::IsNullOrWhiteSpace([string]$Config.ownedTerrain)) { $null } else { [string]$Config.ownedTerrain }
        terrain       = if ([string]::IsNullOrWhiteSpace([string]$Config.terrain)) { $null } else { [string]$Config.terrain }
        mapsDirectory = if ([string]::IsNullOrWhiteSpace([string]$Config.mapsDirectory)) { $null } else { [System.IO.Path]::GetFullPath([string]$Config.mapsDirectory) }
        launcherPath  = if ([string]::IsNullOrWhiteSpace([string]$Config.launcherPath)) { $null } else { [System.IO.Path]::GetFullPath([string]$Config.launcherPath) }
        updatedAt     = (Get-Date).ToString('o')
    }
    Write-JsonFileAtomic -Path $script:AutoModePath -Value $value
    return [pscustomobject]$value
}

function Set-AutoModeTerrainSelection {
    param(
        [Parameter(Mandatory)][string]$OwnedTerrain,
        [Parameter(Mandatory)][string]$Terrain,
        [string]$MapsDirectory
    )
    $config = Get-AutoModeConfig
    $config.ownedTerrain = $OwnedTerrain
    $config.terrain = $Terrain
    if (-not [string]::IsNullOrWhiteSpace($MapsDirectory)) {
        $config.mapsDirectory = $MapsDirectory
    }
    return Save-AutoModeConfig -Config $config
}

function Get-UiSettings {
    $defaults = [ordered]@{
        version                   = 1
        showNormalModeGuide       = $true
        showAutoModeGuide         = $true
        showNormalModeExitWarning = $true
    }
    if (-not (Test-Path -LiteralPath $script:UiSettingsPath -PathType Leaf)) {
        return [pscustomobject]$defaults
    }
    try {
        $saved = [System.IO.File]::ReadAllText($script:UiSettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return [pscustomobject]@{
            version                   = 1
            showNormalModeGuide       = if ($saved.PSObject.Properties.Name -contains 'showNormalModeGuide') { [bool]$saved.showNormalModeGuide } else { $true }
            showAutoModeGuide         = if ($saved.PSObject.Properties.Name -contains 'showAutoModeGuide') { [bool]$saved.showAutoModeGuide } else { $true }
            showNormalModeExitWarning = if ($saved.PSObject.Properties.Name -contains 'showNormalModeExitWarning') { [bool]$saved.showNormalModeExitWarning } else { $true }
        }
    } catch {
        throw "界面设置损坏：$($_.Exception.Message)"
    }
}

function Save-UiSettings {
    param([Parameter(Mandatory)]$Settings)
    $value = [ordered]@{
        version                   = 1
        showNormalModeGuide       = [bool]$Settings.showNormalModeGuide
        showAutoModeGuide         = [bool]$Settings.showAutoModeGuide
        showNormalModeExitWarning = [bool]$Settings.showNormalModeExitWarning
    }
    Write-JsonFileAtomic -Path $script:UiSettingsPath -Value $value
    return [pscustomobject]$value
}

function Write-AutoLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    try {
        Initialize-DataDirectory
        $line = '{0} [{1}] {2}{3}' -f (Get-Date).ToString('o'), $Level, ($Message -replace '[\r\n]+', ' '), [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:AutoLogPath, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-ProcessStartTicks {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        try { return $process.StartTime.ToUniversalTime().Ticks.ToString() } finally { $process.Dispose() }
    } catch { return $null }
}

function Test-TerrainSessionProcess {
    param([Parameter(Mandatory)]$Session)
    try {
        $processId = [int]$Session.processId
        $actualTicks = Get-ProcessStartTicks -ProcessId $processId
        return -not [string]::IsNullOrWhiteSpace($actualTicks) -and $actualTicks -eq [string]$Session.processStartTicks
    } catch { return $false }
}

function Get-TerrainSession {
    if (-not (Test-Path -LiteralPath $script:TerrainSessionPath -PathType Leaf)) { return $null }
    try {
        $session = [System.IO.File]::ReadAllText($script:TerrainSessionPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($property in @('owner','sessionId','processId','processStartTicks')) {
            if (-not ($session.PSObject.Properties.Name -contains $property) -or [string]::IsNullOrWhiteSpace([string]$session.$property)) {
                throw "Missing session property: $property"
            }
        }
        if ([string]$session.owner -notin @('Normal','Auto')) { throw 'Unknown terrain session owner.' }
        return $session
    } catch {
        throw "地图会话记录损坏：$($_.Exception.Message)"
    }
}

function Enter-TerrainOperationLock {
    if ($script:TerrainMutexOwned) { return $true }
    $mutex = New-Object System.Threading.Mutex($false, $script:TerrainMutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            $mutex.Dispose()
            return $false
        }
        $script:TerrainMutex = $mutex
        $script:TerrainMutexOwned = $true
        return $true
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-TerrainOperationLock {
    if ($script:TerrainMutexOwned -and $script:TerrainMutex) {
        try { $script:TerrainMutex.ReleaseMutex() } catch { }
        try { $script:TerrainMutex.Dispose() } catch { }
    }
    $script:TerrainMutex = $null
    $script:TerrainMutexOwned = $false
}

function Start-TerrainSession {
    param([Parameter(Mandatory)][ValidateSet('Normal','Auto')][string]$Owner, [string]$SessionId)
    if (-not $script:TerrainMutexOwned) { throw 'Cannot create a terrain session without the operation lock.' }
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        $script:TerrainSessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { [guid]::NewGuid().ToString('N') } else { $SessionId }
        $script:CurrentSessionOwner = $Owner
        $session = [ordered]@{
            version           = 1
            owner             = $Owner
            sessionId         = $script:TerrainSessionId
            processId         = $process.Id
            processStartTicks = $process.StartTime.ToUniversalTime().Ticks.ToString()
            createdAt         = (Get-Date).ToString('o')
        }
        Write-JsonFileAtomic -Path $script:TerrainSessionPath -Value $session
        return [pscustomobject]$session
    } finally { $process.Dispose() }
}

function Clear-TerrainSession {
    param([string]$ExpectedSessionId)
    if (Test-Path -LiteralPath $script:TerrainSessionPath -PathType Leaf) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId)) {
            $saved = Get-TerrainSession
            if ($saved -and [string]$saved.sessionId -ne $ExpectedSessionId) {
                throw 'Refusing to clear a terrain session owned by another process.'
            }
        }
        Remove-Item -LiteralPath $script:TerrainSessionPath -Force
    }
    $temporary = $script:TerrainSessionPath + '.tmp'
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    $script:TerrainSessionId = $null
    $script:CurrentSessionOwner = $null
}

function Complete-OwnedTerrainSession {
    param([Parameter(Mandatory)][ValidateSet('Normal','Auto')][string]$Owner, [Parameter(Mandatory)][string]$SessionId)
    $state = Get-ActiveSwapState
    if ($state) { [void](Restore-ActiveSwap -ExpectedOwner $Owner -ExpectedSessionId $SessionId) }
    Clear-TerrainSession -ExpectedSessionId $SessionId
    Exit-TerrainOperationLock
}

function Get-SteamLaunchOption {
    if ([string]::IsNullOrWhiteSpace($script:ExecutablePath)) { throw '无法确定当前程序的真实路径。' }
    return ('"' + [System.IO.Path]::GetFullPath($script:ExecutablePath) + '" --auto %command%')
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
                owner         = if ($saved.PSObject.Properties.Name -contains 'owner') { [string]$saved.owner } else { '' }
                sessionId     = if ($saved.PSObject.Properties.Name -contains 'sessionId') { [string]$saved.sessionId } else { '' }
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
    foreach ($name in @('version','status','createdAt','mapsDirectory','ownedFile','ownedName','targetFile','targetName','owner','sessionId')) {
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
        owner         = if ($saved.PSObject.Properties.Name -contains 'owner') { [string]$saved.owner } else { '' }
        sessionId     = if ($saved.PSObject.Properties.Name -contains 'sessionId') { [string]$saved.sessionId } else { '' }
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
        owner         = ''
        sessionId     = ''
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

# IMPORTANT: This function only swaps two filenames; it does not identify terrain content.
# The terrain identity therefore comes entirely from terrain-catalog.json.
# Keep Valve's original mapping here: Emerald Abyss = dota_cavern.*, Reef's Edge = dota_reef.*.
# Never re-derive that mapping from a maps folder while a swap is active.
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
    param(
        [ValidateSet('Normal','Auto')][string]$ExpectedOwner,
        [string]$ExpectedSessionId
    )
    $state = Get-ActiveSwapState
    if (-not $state) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOwner)) {
        $stateOwner = if ($state.PSObject.Properties.Name -contains 'owner') { [string]$state.owner } else { '' }
        $stateSessionId = if ($state.PSObject.Properties.Name -contains 'sessionId') { [string]$state.sessionId } else { '' }
        if ($stateOwner -ne $ExpectedOwner -or [string]::IsNullOrWhiteSpace($ExpectedSessionId) -or $stateSessionId -ne $ExpectedSessionId) {
            throw '当前进程不是该地图替换会话的所有者，拒绝恢复。'
        }
    }
    [void](Invoke-TerrainSwap -MapsDirectory $state.mapsDirectory -OwnedFile $state.ownedFile -TargetFile $state.targetFile)
    if (-not (Test-VpkFile (Join-Path $state.mapsDirectory $state.ownedFile)) -or -not (Test-VpkFile (Join-Path $state.mapsDirectory $state.targetFile))) {
        throw 'Terrain restore verification failed.'
    }
    Clear-ActiveSwapState
    return $state
}

function Invoke-ManagedTerrainSwitch {
    param(
        [Parameter(Mandatory)][string]$MapsDirectory,
        [Parameter(Mandatory)][string]$OwnedFile,
        [Parameter(Mandatory)][string]$TargetFile,
        [Parameter(Mandatory)][string]$OwnedName,
        [Parameter(Mandatory)][string]$TargetName,
        [ValidateSet('Normal','Auto')][string]$Owner,
        [string]$SessionId
    )

    if ($OwnedFile -eq $TargetFile) { throw 'The two terrain files must be different.' }
    $previousState = if (-not [string]::IsNullOrWhiteSpace($Owner)) {
        Restore-ActiveSwap -ExpectedOwner $Owner -ExpectedSessionId $SessionId
    } else {
        Restore-ActiveSwap
    }
    $state = [ordered]@{
        version       = 3
        status        = 'pending'
        createdAt     = (Get-Date).ToString('o')
        mapsDirectory = [System.IO.Path]::GetFullPath($MapsDirectory)
        ownedFile     = $OwnedFile
        ownedName     = $OwnedName
        targetFile    = $TargetFile
        targetName    = $TargetName
        owner         = if ([string]::IsNullOrWhiteSpace($Owner)) { '' } else { $Owner }
        sessionId     = if ([string]::IsNullOrWhiteSpace($SessionId)) { '' } else { $SessionId }
    }

    Write-ActiveSwapState $state
    $swapCompleted = $false
    try {
        [void](Invoke-TerrainSwap -MapsDirectory $MapsDirectory -OwnedFile $OwnedFile -TargetFile $TargetFile)
        $swapCompleted = $true
        $state.status = 'active'
        Write-ActiveSwapState $state
        if (-not (Test-VpkFile (Join-Path $MapsDirectory $OwnedFile)) -or -not (Test-VpkFile (Join-Path $MapsDirectory $TargetFile))) {
            throw 'Terrain apply verification failed.'
        }
    } catch {
        $problem = $_
        if ($swapCompleted) {
            try { [void](Invoke-TerrainSwap -MapsDirectory $MapsDirectory -OwnedFile $OwnedFile -TargetFile $TargetFile) } catch { }
        }
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
    $oldDataDirectory = $script:DataDirectory
    $oldAutoModePath = $script:AutoModePath
    $oldUiSettingsPath = $script:UiSettingsPath
    $oldTerrainSessionPath = $script:TerrainSessionPath
    $oldAutoLogPath = $script:AutoLogPath
    $oldTerrainMutexName = $script:TerrainMutexName
    $oldExecutablePath = $script:ExecutablePath
    $oldForwardCapturePath = [Environment]::GetEnvironmentVariable('DOTA_SWITCHER_FORWARD_CAPTURE', 'Process')
    $script:StateFileOverride = Join-Path $testRoot 'active-swap.json'
    $script:DataDirectory = Join-Path $testRoot '.data'
    $script:AutoModePath = Join-Path $script:DataDirectory 'auto-mode.json'
    $script:UiSettingsPath = Join-Path $script:DataDirectory 'ui-settings.json'
    $script:TerrainSessionPath = Join-Path $script:DataDirectory 'terrain-session.json'
    $script:AutoLogPath = Join-Path $script:DataDirectory 'auto-launch.log'
    $script:TerrainMutexName = 'Local\Dota2TerrainSwitcher.SelfTest.' + [guid]::NewGuid().ToString('N')
    $script:ExecutablePath = Join-Path $testRoot '带 空格\Dota2MapSwitcher.exe'
    try {
        # Canonical catalog contract. These names refer to Valve's ORIGINAL filenames,
        # not to whatever content may temporarily sit under a filename after a swap.
        # In particular: Emerald Abyss -> dota_cavern.*, Reef's Edge -> dota_reef.*.
        $expectedCatalog = [ordered]@{
            divine        = 'dota_ti10.vpk|dota_ti10.png'
            journey       = 'dota_journey.vpk|dota_journey.png'
            overgrown     = 'dota_jungle.vpk|dota_jungle.png'
            summer        = 'dota_summer.vpk|dota_summer.png'
            emerald_abyss = 'dota_cavern.vpk|dota_cavern.png'
            spring        = 'dota_spring.vpk|dota_spring.png'
            reefs_edge    = 'dota_reef.vpk|dota_reef.png'
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

            # Every preview image is deliberately named after its matching VPK.  This
            # invariant catches accidental cross-wiring such as cavern.vpk + reef.png.
            $vpkStem = [System.IO.Path]::GetFileNameWithoutExtension([string]$terrain.file)
            $imageStem = [System.IO.Path]::GetFileNameWithoutExtension([string]$terrain.image)
            if ($vpkStem -ne $imageStem) {
                throw "Terrain catalog file/image mismatch: $($terrain.id) / $($terrain.file) / $($terrain.image)"
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

        # Session ownership: the non-owner must never restore another mode's swap.
        if (-not (Enter-TerrainOperationLock)) { throw 'Normal ownership lock test failed.' }
        $normalSessionId = [guid]::NewGuid().ToString('N')
        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $maps -OwnedFile 'dota_ti10.vpk' -TargetFile 'dota_desert.vpk' -OwnedName 'TI10' -TargetName 'Desert' -Owner Normal -SessionId $normalSessionId)
        [void](Start-TerrainSession -Owner Normal -SessionId $normalSessionId)
        $wrongOwnerRejected = $false
        try { [void](Restore-ActiveSwap -ExpectedOwner Auto -ExpectedSessionId $normalSessionId) } catch { $wrongOwnerRejected = $true }
        if (-not $wrongOwnerRejected -or -not (Get-ActiveSwapState)) { throw 'Normal session priority test failed.' }
        Complete-OwnedTerrainSession -Owner Normal -SessionId $normalSessionId
        if (Get-ActiveSwapState) { throw 'Normal session cleanup test failed.' }

        if (-not (Enter-TerrainOperationLock)) { throw 'Auto ownership lock test failed.' }
        $autoSessionId = [guid]::NewGuid().ToString('N')
        [void](Start-TerrainSession -Owner Auto -SessionId $autoSessionId)
        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $maps -OwnedFile 'dota_ti10.vpk' -TargetFile 'dota_desert.vpk' -OwnedName 'TI10' -TargetName 'Desert' -Owner Auto -SessionId $autoSessionId)
        $wrongOwnerRejected = $false
        try { [void](Restore-ActiveSwap -ExpectedOwner Normal -ExpectedSessionId $autoSessionId) } catch { $wrongOwnerRejected = $true }
        if (-not $wrongOwnerRejected) { throw 'Auto session ownership test failed.' }
        Complete-OwnedTerrainSession -Owner Auto -SessionId $autoSessionId

        $launchOption = Get-SteamLaunchOption
        if ($launchOption -ne ('"' + [System.IO.Path]::GetFullPath($script:ExecutablePath) + '" --auto %command%')) { throw 'Dynamic launch option test failed.' }
        if (([regex]::Matches($launchOption, [regex]::Escape('%command%'))).Count -ne 1) { throw 'Launch option must contain %command% exactly once.' }
        if (-not $launchOption.StartsWith(('"' + [System.IO.Path]::GetFullPath($script:ExecutablePath) + '" --auto '))) { throw 'Launch option path quoting/order test failed.' }

        # UI settings are backward-compatible: every field defaults to true when
        # the file or a property is absent, and each choice persists independently.
        $defaultUiSettings = Get-UiSettings
        if (-not $defaultUiSettings.showNormalModeGuide -or -not $defaultUiSettings.showAutoModeGuide -or -not $defaultUiSettings.showNormalModeExitWarning) {
            throw 'UI setting default test failed.'
        }
        Write-JsonFileAtomic -Path $script:UiSettingsPath -Value ([ordered]@{ version=1 })
        $legacyUiSettings = Get-UiSettings
        if (-not $legacyUiSettings.showNormalModeGuide -or -not $legacyUiSettings.showAutoModeGuide -or -not $legacyUiSettings.showNormalModeExitWarning) {
            throw 'Legacy UI setting fallback test failed.'
        }
        $legacyUiSettings.showNormalModeGuide = $false
        $savedUiSettings = Save-UiSettings $legacyUiSettings
        if ((Get-UiSettings).showNormalModeGuide) { throw 'Normal guide persistence test failed.' }
        $savedUiSettings.showAutoModeGuide = $false
        $savedUiSettings = Save-UiSettings $savedUiSettings
        if ((Get-UiSettings).showAutoModeGuide) { throw 'Auto guide persistence test failed.' }
        $savedUiSettings.showNormalModeExitWarning = $false
        [void](Save-UiSettings $savedUiSettings)
        if ((Get-UiSettings).showNormalModeExitWarning) { throw 'Normal exit warning persistence test failed.' }

        # Activating in the GUI is configuration-only. Saving the enabled config
        # must not change either terrain VPK byte-for-byte.
        $ownedBeforeActivation = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk')))
        $targetBeforeActivation = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_desert.vpk')))
        $config = [pscustomobject]@{ enabled=$true; ownedTerrain='divine'; terrain='desert'; mapsDirectory=$maps; launcherPath=$script:ExecutablePath }
        $savedConfig = Save-AutoModeConfig -Config $config
        if (-not $savedConfig.enabled -or $savedConfig.terrain -ne 'desert' -or (Get-AutoModeConfig).ownedTerrain -ne 'divine') { throw 'Auto config persistence test failed.' }
        $savedConfig = Set-AutoModeTerrainSelection -OwnedTerrain 'divine' -Terrain 'journey'
        if (-not $savedConfig.enabled -or $savedConfig.terrain -ne 'journey' -or $savedConfig.launcherPath -ne $script:ExecutablePath) {
            throw 'Changing the automatic terrain must preserve the enabled switch and launcher path.'
        }
        $savedConfig = Set-AutoModeTerrainSelection -OwnedTerrain 'divine' -Terrain 'desert'
        if ($ownedBeforeActivation -ne [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk'))) -or
            $targetBeforeActivation -ne [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_desert.vpk')))) {
            throw 'Saving or enabling an automatic terrain unexpectedly modified a VPK.'
        }

        # Compile a tiny fake dota2.exe that records its exact argv. This verifies
        # the full C# launcher -> PowerShell -> ProcessStartInfo forwarding path.
        $forwardCaptureExe = Join-Path $testRoot 'dota2.exe'
        $forwardCaptureSource = @'
using System;
using System.IO;
using System.Text;

internal static class DotaForwardCapture
{
    private static int Main(string[] args)
    {
        string path = Environment.GetEnvironmentVariable("DOTA_SWITCHER_FORWARD_CAPTURE");
        if (String.IsNullOrWhiteSpace(path)) { return 2; }
        File.WriteAllLines(path, args, new UTF8Encoding(false));
        return 0;
    }
}
'@
        Add-Type -TypeDefinition $forwardCaptureSource -Language CSharp -OutputAssembly $forwardCaptureExe -OutputType ConsoleApplication

        # Enabled with no extra Dota arguments.
        $noArgumentMarker = Join-Path $testRoot 'enabled-no-arguments.txt'
        [Environment]::SetEnvironmentVariable('DOTA_SWITCHER_FORWARD_CAPTURE', $noArgumentMarker, 'Process')
        Invoke-AutoLaunchMode -Command @($forwardCaptureExe)
        if (-not (Test-Path -LiteralPath $noArgumentMarker -PathType Leaf) -or @(Get-Content -LiteralPath $noArgumentMarker).Count -ne 0) {
            throw 'Enabled auto forwarding without extra arguments failed.'
        }

        # Enabled with multiple flags plus values containing spaces and quotes.
        $expectedForwardedArguments = @('-perfectworld','-novid','-console','value with space','quoted "value"')
        $enabledArgumentMarker = Join-Path $testRoot 'enabled-multiple-arguments.txt'
        [Environment]::SetEnvironmentVariable('DOTA_SWITCHER_FORWARD_CAPTURE', $enabledArgumentMarker, 'Process')
        Invoke-AutoLaunchMode -Command (@($forwardCaptureExe) + $expectedForwardedArguments)
        $enabledForwardedArguments = @(Get-Content -LiteralPath $enabledArgumentMarker -Encoding UTF8)
        if ([string]::Join("`n", $enabledForwardedArguments) -ne [string]::Join("`n", $expectedForwardedArguments)) {
            throw 'Enabled auto mode did not preserve all Dota arguments and quoting.'
        }
        if (Get-ActiveSwapState -or (Test-Path -LiteralPath $script:TerrainSessionPath)) { throw 'Auto launch cleanup test failed.' }
        if ([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk'))[4] -ne 2) { throw 'Auto launch restore test failed.' }

        # Disabled must still preserve every game argument while leaving VPKs alone.
        $savedConfig.enabled = $false
        [void](Save-AutoModeConfig -Config $savedConfig)
        $disabledArgumentMarker = Join-Path $testRoot 'disabled-multiple-arguments.txt'
        [Environment]::SetEnvironmentVariable('DOTA_SWITCHER_FORWARD_CAPTURE', $disabledArgumentMarker, 'Process')
        Invoke-AutoLaunchMode -Command (@($forwardCaptureExe) + $expectedForwardedArguments)
        $forwardDeadline = (Get-Date).AddSeconds(5)
        while (-not (Test-Path -LiteralPath $disabledArgumentMarker -PathType Leaf) -and (Get-Date) -lt $forwardDeadline) { Start-Sleep -Milliseconds 50 }
        if (-not (Test-Path -LiteralPath $disabledArgumentMarker -PathType Leaf)) { throw 'Disabled auto command forwarding test failed.' }
        $disabledForwardedArguments = @(Get-Content -LiteralPath $disabledArgumentMarker -Encoding UTF8)
        if ([string]::Join("`n", $disabledForwardedArguments) -ne [string]::Join("`n", $expectedForwardedArguments)) {
            throw 'Disabled auto mode did not preserve all Dota arguments and quoting.'
        }
        if ($ownedBeforeActivation -ne [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_ti10.vpk'))) -or
            $targetBeforeActivation -ne [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $maps 'dota_desert.vpk')))) {
            throw 'Disabled auto mode modified a VPK.'
        }
        Write-Output 'SELF-TEST PASSED'
    } finally {
        Exit-TerrainOperationLock
        $script:StateFileOverride = $oldStateFileOverride
        $script:DataDirectory = $oldDataDirectory
        $script:AutoModePath = $oldAutoModePath
        $script:UiSettingsPath = $oldUiSettingsPath
        $script:TerrainSessionPath = $oldTerrainSessionPath
        $script:AutoLogPath = $oldAutoLogPath
        $script:TerrainMutexName = $oldTerrainMutexName
        $script:ExecutablePath = $oldExecutablePath
        [Environment]::SetEnvironmentVariable('DOTA_SWITCHER_FORWARD_CAPTURE', $oldForwardCapturePath, 'Process')
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-OriginalDotaCommand {
    param([Parameter(Mandatory)][string[]]$Command)
    if ($Command.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$Command[0])) {
        throw 'Steam did not provide the original %command%.'
    }
    $executable = [System.IO.Path]::GetFullPath([string]$Command[0])
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Steam original command does not exist: $executable" }
    if (-not [string]::IsNullOrWhiteSpace($script:ExecutablePath) -and
        [string]::Equals($executable, [System.IO.Path]::GetFullPath($script:ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to recursively launch the terrain switcher.'
    }
    $arguments = @()
    if ($Command.Count -gt 1) {
        $arguments = @($Command[1..($Command.Count - 1)] | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Value ([string]$_) })
    }
    Write-AutoLog ("Dota command: executable={0}; argumentCount={1}" -f $executable, $arguments.Count)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = [string]::Join(' ', $arguments)
    $startInfo.WorkingDirectory = Split-Path -Parent $executable
    $startInfo.UseShellExecute = $false
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        $process.Dispose()
        throw 'The original Dota command did not start a process.'
    }
    Write-AutoLog ("Dota started: pid={0}" -f $process.Id)
    return $process
}

function Wait-DotaSessionExit {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$StartedProcess, [Parameter(Mandatory)][string]$ExecutablePath)
    $isDirectDota = [string]::Equals([System.IO.Path]::GetFileNameWithoutExtension($ExecutablePath), 'dota2', [System.StringComparison]::OrdinalIgnoreCase)
    if ($isDirectDota) {
        $StartedProcess.WaitForExit()
        Write-AutoLog 'Dota process exited'
        return
    }

    $deadline = (Get-Date).AddSeconds(30)
    $exitGraceDeadline = $null
    $observedDota = $false
    while ((Get-Date) -lt $deadline) {
        $dotaProcesses = @(Get-Process -Name dota2 -ErrorAction SilentlyContinue)
        if ($dotaProcesses.Count -gt 0) {
            $observedDota = $true
            break
        }
        if ($StartedProcess.HasExited) {
            if (-not $exitGraceDeadline) { $exitGraceDeadline = (Get-Date).AddSeconds(10) }
            if ((Get-Date) -ge $exitGraceDeadline) { break }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $observedDota) {
        if (-not $StartedProcess.HasExited) { $StartedProcess.WaitForExit() }
        Write-AutoLog 'The forwarded command ended without an observable dota2 process' 'WARN'
        return
    }
    do {
        Start-Sleep -Milliseconds 500
        $dotaProcesses = @(Get-Process -Name dota2 -ErrorAction SilentlyContinue)
    } while ($dotaProcesses.Count -gt 0)
    Write-AutoLog 'Dota process exited'
}

function Get-CatalogTerrainById {
    param([Parameter(Mandatory)]$Catalog, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    return @($Catalog | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

function Resolve-AutoMapsDirectory {
    param([Parameter(Mandatory)]$Config)
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.mapsDirectory) -and
        (Test-VpkFile (Join-Path ([string]$Config.mapsDirectory) 'dota.vpk'))) {
        return [System.IO.Path]::GetFullPath([string]$Config.mapsDirectory)
    }
    $installs = @(Find-DotaInstallations)
    if ($installs.Count -lt 1) { return $null }
    return Get-MapsDirectory $installs[0]
}

function Invoke-AutoLaunchMode {
    param([string[]]$Command)
    Write-AutoLog 'AutoLaunch started'
    $startedProcess = $null
    $autoSessionStarted = $false
    $dotaStarted = $false
    try {
        if (-not $Command -or $Command.Count -lt 1) { throw 'Steam did not provide the original %command%.' }
        $configError = $null
        try { $config = Get-AutoModeConfig } catch {
            $configError = $_
            $config = [pscustomobject]@{ enabled=$true; ownedTerrain=$null; terrain=$null; mapsDirectory=$null; launcherPath=$null }
        }
        Write-AutoLog ("AutoMode {0}" -f $(if ($configError) { 'configuration invalid' } elseif ($config.enabled) { 'enabled' } else { 'disabled' }))
        if (-not $config.enabled) {
            $startedProcess = Start-OriginalDotaCommand -Command $Command
            $dotaStarted = $true
            return
        }

        $lockAcquired = Enter-TerrainOperationLock
        $owner = 'Unknown'
        if (-not $lockAcquired) {
            $busyDeadline = (Get-Date).AddSeconds(10)
            do {
                try {
                    $existingSession = Get-TerrainSession
                    if ($existingSession -and (Test-TerrainSessionProcess $existingSession)) {
                        $owner = [string]$existingSession.owner
                        break
                    }
                } catch { Write-AutoLog $_.Exception.Message 'WARN' }
                Start-Sleep -Milliseconds 100
                $lockAcquired = Enter-TerrainOperationLock
            } while (-not $lockAcquired -and (Get-Date) -lt $busyDeadline)
        }
        if (-not $lockAcquired) {
            if ($owner -eq 'Normal') {
                Write-AutoLog 'Auto mode bypassed because NormalMode owns the terrain session'
            } else {
                Write-AutoLog ("Auto mode bypassed because another terrain session owns the operation lock: {0}" -f $owner) 'WARN'
            }
            $startedProcess = Start-OriginalDotaCommand -Command $Command
            $dotaStarted = $true
            return
        }

        try {
            $staleSession = Get-TerrainSession
            if ($staleSession) {
                if (Test-TerrainSessionProcess $staleSession) { throw 'The terrain session mutex and owner record disagree.' }
                Clear-TerrainSession
            }
        } catch {
            Write-AutoLog ("Stale session cleanup failed: {0}" -f $_.Exception.Message) 'WARN'
            if (Test-Path -LiteralPath $script:TerrainSessionPath -PathType Leaf) { Remove-Item -LiteralPath $script:TerrainSessionPath -Force }
        }
        [void](Start-TerrainSession -Owner Auto)
        $autoSessionStarted = $true

        Write-AutoLog 'Recovery check'
        $leftover = Get-ActiveSwapState
        if ($leftover) {
            if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) { throw 'Cannot recover a previous terrain while Dota 2 is running.' }
            Write-AutoLog 'Restore started for previous abnormal state'
            [void](Restore-ActiveSwap)
            Write-AutoLog 'Restore succeeded for previous abnormal state'
        }

        if ($configError) { throw $configError }

        $catalog = Read-TerrainCatalog
        $owned = Get-CatalogTerrainById -Catalog $catalog -Id ([string]$config.ownedTerrain)
        $target = Get-CatalogTerrainById -Catalog $catalog -Id ([string]$config.terrain)
        if (-not $owned -or -not $target -or [string]$owned.id -eq [string]$target.id) {
            throw 'The saved automatic terrain selection is missing, invalid, or uses the same owned and target terrain.'
        }
        Write-AutoLog ("Selected auto terrain: {0}" -f [string]$target.id)
        $mapsDirectory = Resolve-AutoMapsDirectory -Config $config
        if ([string]::IsNullOrWhiteSpace($mapsDirectory)) { throw 'Dota 2 installation could not be found for automatic mode.' }
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) { throw 'Dota 2 is already running; automatic terrain changes were skipped.' }

        Write-AutoLog 'Apply started'
        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $mapsDirectory -OwnedFile $owned.file -TargetFile $target.file -OwnedName $owned.zh -TargetName $target.zh -Owner Auto -SessionId $script:TerrainSessionId)
        Write-AutoLog 'Apply succeeded'
        $startedProcess = Start-OriginalDotaCommand -Command $Command
        $dotaStarted = $true
        Wait-DotaSessionExit -StartedProcess $startedProcess -ExecutablePath ([string]$Command[0])
    } catch {
        Write-AutoLog ("AutoLaunch failed: {0}" -f $_.Exception.Message) 'ERROR'
        if (-not $dotaStarted) {
            try {
                $failedState = Get-ActiveSwapState
                if ($failedState -and [string]$failedState.owner -eq 'Auto' -and [string]$failedState.sessionId -eq $script:TerrainSessionId) {
                    Write-AutoLog 'Restore started before fallback launch'
                    [void](Restore-ActiveSwap -ExpectedOwner Auto -ExpectedSessionId $script:TerrainSessionId)
                    Write-AutoLog 'Restore succeeded before fallback launch'
                }
            } catch {
                Write-AutoLog ("Pre-launch restore failed: {0}" -f $_.Exception.Message) 'ERROR'
            }
            try {
                $startedProcess = Start-OriginalDotaCommand -Command $Command
                $dotaStarted = $true
                Write-AutoLog 'Dota was started with the safest available terrain state after the automatic-mode failure' 'WARN'
            } catch {
                Write-AutoLog ("Fallback Dota launch failed: {0}" -f $_.Exception.Message) 'ERROR'
            }
        }
    } finally {
        if ($autoSessionStarted) {
            try {
                $state = Get-ActiveSwapState
                if ($state -and [string]$state.owner -eq 'Auto' -and [string]$state.sessionId -eq $script:TerrainSessionId) {
                    Write-AutoLog 'Restore started'
                    [void](Restore-ActiveSwap -ExpectedOwner Auto -ExpectedSessionId $script:TerrainSessionId)
                    Write-AutoLog 'Restore succeeded'
                }
            } catch {
                Write-AutoLog ("Restore failed: {0}" -f $_.Exception.Message) 'ERROR'
            }
            try { Clear-TerrainSession -ExpectedSessionId $script:TerrainSessionId } catch { Write-AutoLog $_.Exception.Message 'ERROR' }
        }
        Exit-TerrainOperationLock
        if ($startedProcess) { $startedProcess.Dispose() }
        Write-AutoLog 'AutoLaunch finished'
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($AutoLaunch) {
    Invoke-AutoLaunchMode -Command $AutoCommand
    return
}

if (-not $UiSmokeTest -and [string]::IsNullOrWhiteSpace($UiSnapshotPath) -and -not $UiCloseTest -and -not $UiCrashRecoveryTest) {
    Import-RegistryActiveSwapState
    Import-LegacyActiveSwapState
}

if ($RestoreAndExit) {
    try {
        if (-not (Enter-TerrainOperationLock)) { throw '另一个地图替换会话仍在运行，请先结束该会话。' }
        $session = Get-TerrainSession
        if ($session -and (Test-TerrainSessionProcess $session)) { throw '另一个地图替换会话仍在运行，请先结束该会话。' }
        if ($session) { Clear-TerrainSession }
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
    } finally { Exit-TerrainOperationLock }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Dota 2" Width="1040" Height="850" MinWidth="1000" MinHeight="700" WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip" Background="#081016" Foreground="#E4D7B4" FontFamily="Microsoft YaHei UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <LinearGradientBrush x:Key="AppBackgroundBrush" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#0D1A21" Offset="0"/><GradientStop Color="#081016" Offset="0.55"/><GradientStop Color="#0A1318" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="PanelBackgroundBrush" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#17252B" Offset="0"/><GradientStop Color="#0C161B" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="PanelInnerBrush" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#122129" Offset="0"/><GradientStop Color="#091217" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="PrimaryButtonBrush" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#185CAB" Offset="0"/><GradientStop Color="#0C3D85" Offset="0.5"/><GradientStop Color="#082B60" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="SecondaryButtonBrush" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#243842" Offset="0"/><GradientStop Color="#111E25" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="TerrainCardBackgroundBrush" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#19262B" Offset="0"/><GradientStop Color="#0A1216" Offset="1"/></LinearGradientBrush>
    <SolidColorBrush x:Key="IronOuterBorderBrush" Color="#303C3F"/>
    <SolidColorBrush x:Key="IronInnerBorderBrush" Color="#566164"/>
    <SolidColorBrush x:Key="GoldBorderBrush" Color="#92712F"/>
    <SolidColorBrush x:Key="PrimaryGoldBrush" Color="#D6A83B"/>
    <SolidColorBrush x:Key="SecondaryGoldBrush" Color="#B48731"/>
    <SolidColorBrush x:Key="MagicBlueBrush" Color="#1C6CD0"/>
    <SolidColorBrush x:Key="MagicBlueDarkBrush" Color="#0C3D85"/>
    <SolidColorBrush x:Key="TargetPurpleBrush" Color="#8740BE"/>
    <SolidColorBrush x:Key="TargetPurpleDarkBrush" Color="#512078"/>
    <SolidColorBrush x:Key="OwnedGreenBrush" Color="#64BC31"/>
    <SolidColorBrush x:Key="PrimaryTextBrush" Color="#E4D7B4"/>
    <SolidColorBrush x:Key="SecondaryTextBrush" Color="#AFA895"/>
    <SolidColorBrush x:Key="DisabledTextBrush" Color="#6E716C"/>
    <SolidColorBrush x:Key="ErrorBorderBrush" Color="#713A32"/>
    <SolidColorBrush x:Key="WarningBorderBrush" Color="#8C692A"/>

    <Style x:Key="RtsPanelStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource PanelBackgroundBrush}"/><Setter Property="BorderBrush" Value="{StaticResource IronOuterBorderBrush}"/><Setter Property="BorderThickness" Value="2"/><Setter Property="CornerRadius" Value="3"/>
    </Style>
    <Style x:Key="RtsSecondaryButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource PrimaryGoldBrush}"/><Setter Property="Background" Value="{StaticResource SecondaryButtonBrush}"/><Setter Property="BorderBrush" Value="{StaticResource IronInnerBorderBrush}"/><Setter Property="BorderThickness" Value="2"/><Setter Property="Padding" Value="14,6"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/><Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Outer" Background="#080D10" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="2">
          <Border x:Name="Inner" Margin="2" Background="{TemplateBinding Background}" BorderBrush="{StaticResource GoldBorderBrush}" BorderThickness="1" CornerRadius="1">
            <ContentPresenter x:Name="Content" Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Outer" Property="BorderBrush" Value="{StaticResource PrimaryGoldBrush}"/><Setter TargetName="Inner" Property="Background" Value="#19394D"/><Setter Property="Foreground" Value="#F2CE69"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Inner" Property="Background" Value="#081B2F"/><Setter TargetName="Content" Property="RenderTransform"><Setter.Value><TranslateTransform Y="1"/></Setter.Value></Setter></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Outer" Property="Opacity" Value="0.46"/><Setter Property="Foreground" Value="{StaticResource DisabledTextBrush}"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="RtsPrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource RtsSecondaryButtonStyle}"><Setter Property="Background" Value="{StaticResource PrimaryButtonBrush}"/><Setter Property="BorderBrush" Value="#415C72"/><Setter Property="Foreground" Value="#F0C957"/></Style>
    <Style x:Key="RtsAttentionButtonStyle" TargetType="Button" BasedOn="{StaticResource RtsSecondaryButtonStyle}"><Setter Property="Background" Value="#5A3E0D"/><Setter Property="BorderBrush" Value="#E0A92E"/><Setter Property="Foreground" Value="#FFE184"/><Setter Property="FontWeight" Value="Bold"/></Style>
    <Style x:Key="RtsSmallButtonStyle" TargetType="Button" BasedOn="{StaticResource RtsSecondaryButtonStyle}"><Setter Property="Padding" Value="11,5"/><Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Normal"/></Style>
    <Style x:Key="RtsStatusButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="#8ED36A"/><Setter Property="Background" Value="#172A1B"/><Setter Property="BorderBrush" Value="#47673A"/><Setter Property="BorderThickness" Value="2"/><Setter Property="Padding" Value="14,6"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="#090E0A" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="2" CornerRadius="2"><Border Margin="2" Background="{TemplateBinding Background}" BorderBrush="#6B713B" BorderThickness="1"><ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource RtsSecondaryButtonStyle}"/>

    <Style x:Key="ModeChoiceStyle" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource PrimaryTextBrush}"/><Setter Property="Background" Value="{StaticResource PanelInnerBrush}"/><Setter Property="BorderBrush" Value="{StaticResource IronInnerBorderBrush}"/><Setter Property="BorderThickness" Value="2"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="Outer" Background="#080E12" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
          <Border x:Name="Inner" Margin="3" Background="{TemplateBinding Background}" BorderBrush="{StaticResource GoldBorderBrush}" BorderThickness="1" CornerRadius="1" Padding="22,14"><ContentPresenter/></Border>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Outer" Property="BorderBrush" Value="#B08A3D"/><Setter TargetName="Inner" Property="Background" Value="#172B35"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="Outer" Property="BorderBrush" Value="{StaticResource MagicBlueBrush}"/><Setter TargetName="Outer" Property="BorderThickness" Value="3"/><Setter TargetName="Inner" Property="BorderBrush" Value="#5C91D7"/><Setter TargetName="Inner" Property="Background" Value="#102B49"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="RtsCheckboxStyle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource PrimaryTextBrush}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><StackPanel Orientation="Horizontal"><Border x:Name="Box" Width="17" Height="17" Margin="0,0,8,0" Background="#081015" BorderBrush="{StaticResource GoldBorderBrush}" BorderThickness="1"><TextBlock x:Name="Mark" Text="✓" Foreground="#6EA8E8" FontWeight="Bold" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/></Border><ContentPresenter VerticalAlignment="Center"/></StackPanel><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Mark" Property="Visibility" Value="Visible"/><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource MagicBlueBrush}"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource PrimaryGoldBrush}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="15"/><Setter Property="Background" Value="#081015"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="{TemplateBinding Background}"><Border BorderBrush="#39474A" BorderThickness="1"/><Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border x:Name="ThumbBorder" Margin="2" Background="#17344A" BorderBrush="{StaticResource GoldBorderBrush}" BorderThickness="1" CornerRadius="2"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#20527C"/><Setter TargetName="ThumbBorder" Property="BorderBrush" Value="{StaticResource PrimaryGoldBrush}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0"/></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border Margin="9" Background="#05090B" BorderBrush="{StaticResource IronOuterBorderBrush}" BorderThickness="3" CornerRadius="4">
    <Border Margin="3" Background="{StaticResource AppBackgroundBrush}" BorderBrush="{StaticResource GoldBorderBrush}" BorderThickness="1" CornerRadius="2">
      <Grid Margin="13,11,13,13">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Name="TitleText" Text="Dota 2" Margin="7,0,7,12" FontSize="24" FontWeight="Bold" Foreground="{StaticResource PrimaryGoldBrush}" VerticalAlignment="Center"/>
        <Grid Grid.Row="1">
          <Grid Name="ModeSelectionPage">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel Grid.Row="0" HorizontalAlignment="Center" VerticalAlignment="Center">
              <TextBlock Text="选择使用模式" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource PrimaryGoldBrush}" HorizontalAlignment="Center" Margin="0,0,0,30"/>
              <RadioButton Name="NormalModeChoice" GroupName="ModeChoice" Style="{StaticResource ModeChoiceStyle}" Width="530" Height="98" Margin="0,0,0,16"><StackPanel><TextBlock Text="普通模式" FontSize="19" FontWeight="SemiBold" Foreground="{StaticResource PrimaryTextBrush}"/><TextBlock Text="临时替换地图，关闭程序时自动恢复" Margin="0,6,0,0" FontSize="13" Foreground="{StaticResource SecondaryTextBrush}"/></StackPanel></RadioButton>
              <RadioButton Name="AutoModeChoice" GroupName="ModeChoice" Style="{StaticResource ModeChoiceStyle}" Width="530" Height="98"><StackPanel><TextBlock Text="自动替换模式" FontSize="19" FontWeight="SemiBold" Foreground="{StaticResource PrimaryTextBrush}"/><TextBlock Text="从 Steam 启动游戏时自动替换并在退出后恢复" Margin="0,6,0,0" FontSize="13" Foreground="{StaticResource SecondaryTextBrush}"/></StackPanel></RadioButton>
            </StackPanel>
            <Button Grid.Row="1" Name="NextButton" Content="下一步  ›" Style="{StaticResource RtsPrimaryButtonStyle}" Width="126" Height="42" HorizontalAlignment="Right" Margin="0,12,7,0" IsEnabled="False"/>
          </Grid>
          <Grid Name="TerrainPage" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border Grid.Row="0" Style="{StaticResource RtsPanelStyle}" Margin="7,2,7,9" Padding="8">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <WrapPanel Grid.Row="0" Grid.Column="0" Name="AutoActionsPanel" Visibility="Collapsed">
                  <Button Name="ActivateAutoButton" Content="开启自动替换" Style="{StaticResource RtsPrimaryButtonStyle}" MinWidth="140" Height="38" Margin="0,0,10,0"/>
                  <Button Name="CancelAutoButton" Content="关闭自动替换" Style="{StaticResource RtsSecondaryButtonStyle}" MinWidth="112" Height="38" Margin="0,0,10,0"/>
                  <Button Name="CopyLaunchButton" Content="复制 Steam 启动参数" Style="{StaticResource RtsPrimaryButtonStyle}" MinWidth="190" Height="38"/>
                </WrapPanel>
                <Button Grid.Row="0" Grid.Column="1" Name="ResetTutorialButton" Content="重置教程" Style="{StaticResource RtsSmallButtonStyle}" MinWidth="105" Height="36"/>
                <Border Grid.Row="1" Grid.ColumnSpan="2" Name="CopyStatusBorder" Margin="0,8,0,0" Padding="10,7" Background="#12261A" BorderBrush="#607B3C" BorderThickness="1" Visibility="Collapsed">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Name="CopyStatusText" Foreground="#9DD57B" FontSize="13" TextWrapping="Wrap" VerticalAlignment="Center"/>
                    <Button Grid.Column="1" Name="CopyStatusCloseButton" Content="×" Style="{StaticResource RtsSmallButtonStyle}" Width="30" Height="26" Margin="10,0,0,0" Padding="0" FontSize="16" ToolTip="关闭提示"/>
                  </Grid>
                </Border>
              </Grid>
            </Border>
            <Border Grid.Row="1" Margin="7,0,7,0" Background="#080F13" BorderBrush="{StaticResource IronInnerBorderBrush}" BorderThickness="2" CornerRadius="2">
              <Border Margin="2" BorderBrush="#705F482B" BorderThickness="1"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="#081116"><WrapPanel Name="TerrainPanel" Width="984" HorizontalAlignment="Center" VerticalAlignment="Top"/></ScrollViewer></Border>
            </Border>
            <Grid Grid.Row="2" Margin="7,11,7,0"><Button Name="BackButton" Content="‹  上一步" Style="{StaticResource RtsSecondaryButtonStyle}" Width="120" Height="40" HorizontalAlignment="Left"/></Grid>
          </Grid>
          <Border Name="DialogOverlay" Background="#42000000" Visibility="Collapsed" Panel.ZIndex="50"/>
        </Grid>
      </Grid>
    </Border>
  </Border>
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
$uiNames = @('TitleText','ModeSelectionPage','TerrainPage','NormalModeChoice','AutoModeChoice','NextButton','AutoActionsPanel','ActivateAutoButton','CancelAutoButton','CopyLaunchButton','ResetTutorialButton','CopyStatusBorder','CopyStatusText','CopyStatusCloseButton','TerrainPanel','BackButton','DialogOverlay')
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
$script:AutoSelectedOwnedFile = $null
$script:AutoSelectedTargetFile = $null
$script:CurrentUiMode = $null
$script:NormalGuideShownThisRun = $false
$script:AutoGuideShownThisRun = $false
$script:NormalModeInitialized = $false
$script:AutoSelectionChangedThisRun = $false
$script:SessionTimer = $null
$script:DialogSnapshotPath = $null
$script:DialogSnapshotDpi = 96
$script:IsBusy = $false
$script:AllowWindowClose = $false
$script:ForeignSessionActive = $false
try { $script:UiSettings = Get-UiSettings } catch {
    $script:UiSettings = [pscustomobject]@{ version=1; showNormalModeGuide=$true; showAutoModeGuide=$true; showNormalModeExitWarning=$true }
}
$script:TerrainImageDirectory = Join-Path $script:ResourceDirectory 'terrains'
if (-not (Test-Path -LiteralPath $script:TerrainImageDirectory -PathType Container)) {
    $script:TerrainImageDirectory = Join-Path $script:ResourceDirectory 'assets\terrains'
}

function Get-UiBrush([string]$Color) {
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Get-UiResource([string]$Name) {
    return $window.FindResource($Name)
}

function Save-VisualSnapshot {
    param([Parameter(Mandatory)]$Visual, [Parameter(Mandatory)][string]$Path, [int]$Dpi = 96)
    $Visual.UpdateLayout()
    $scale = $Dpi / 96.0
    $width = [Math]::Max(1, [int][Math]::Ceiling($Visual.ActualWidth * $scale))
    $height = [Math]::Max(1, [int][Math]::Ceiling($Visual.ActualHeight * $scale))
    $render = New-Object Windows.Media.Imaging.RenderTargetBitmap $width, $height, $Dpi, $Dpi, ([Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($Visual)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    [void]$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $stream = [System.IO.File]::Create($fullPath)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    return $fullPath
}

function Update-CardVisuals {
    $visibleOwnedFile = if ($script:CurrentUiMode -eq 'Auto') { $script:AutoSelectedOwnedFile } else { $script:SelectedOwnedFile }
    $visibleTargetFile = if ($script:CurrentUiMode -eq 'Auto') { $script:AutoSelectedTargetFile } else { $script:SelectedTargetFile }
    foreach ($item in $script:CardLookup.Values) {
        $item.Card.BorderBrush = Get-UiResource 'IronOuterBorderBrush'
        $item.Card.BorderThickness = New-Object Windows.Thickness 2
        $item.Card.Effect = $null
        $item.InnerBorder.BorderBrush = Get-UiResource 'GoldBorderBrush'
        $item.InnerBorder.Background = Get-UiResource 'TerrainCardBackgroundBrush'
        $item.Badge.Visibility = [Windows.Visibility]::Collapsed
        $item.BadgeText.Text = ''
        if ($item.File -eq $visibleOwnedFile) {
            $item.Card.BorderBrush = Get-UiResource 'MagicBlueBrush'
            $item.Card.BorderThickness = New-Object Windows.Thickness 3
            $item.InnerBorder.BorderBrush = Get-UiBrush '#6E9ED8'
            $item.Badge.Background = Get-UiBrush '#101B16'
            $item.Badge.BorderBrush = Get-UiResource 'OwnedGreenBrush'
            $item.Badge.BorderThickness = New-Object Windows.Thickness 1
            $item.BadgeText.Foreground = Get-UiResource 'OwnedGreenBrush'
            $item.BadgeText.Text = $text.ownedBadge
            $item.Badge.Visibility = [Windows.Visibility]::Visible
            $shadow = New-Object Windows.Media.Effects.DropShadowEffect
            $shadow.Color = [Windows.Media.Colors]::SteelBlue
            $shadow.BlurRadius = 7
            $shadow.Opacity = 0.22
            $shadow.ShadowDepth = 0
            $item.Card.Effect = $shadow
        } elseif ($item.File -eq $visibleTargetFile) {
            $item.Card.BorderBrush = Get-UiResource 'TargetPurpleBrush'
            $item.Card.BorderThickness = New-Object Windows.Thickness 3
            $item.InnerBorder.BorderBrush = Get-UiBrush '#A06BCD'
            $item.Badge.Background = Get-UiBrush '#1B1023'
            $item.Badge.BorderBrush = Get-UiResource 'TargetPurpleBrush'
            $item.Badge.BorderThickness = New-Object Windows.Thickness 1
            $item.BadgeText.Foreground = Get-UiBrush '#C994E9'
            $item.BadgeText.Text = $text.targetBadge
            $item.Badge.Visibility = [Windows.Visibility]::Visible
            $shadow = New-Object Windows.Media.Effects.DropShadowEffect
            $shadow.Color = [Windows.Media.Color]::FromRgb(112,43,163)
            $shadow.BlurRadius = 7
            $shadow.Opacity = 0.22
            $shadow.ShadowDepth = 0
            $item.Card.Effect = $shadow
        }
    }
}

function Set-CardHover {
    param([Parameter(Mandatory)]$Card, [Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][bool]$Hovered)
    $visibleOwnedFile = if ($script:CurrentUiMode -eq 'Auto') { $script:AutoSelectedOwnedFile } else { $script:SelectedOwnedFile }
    $visibleTargetFile = if ($script:CurrentUiMode -eq 'Auto') { $script:AutoSelectedTargetFile } else { $script:SelectedTargetFile }
    if ($FileName -eq $visibleOwnedFile -or $FileName -eq $visibleTargetFile) { return }
    $Card.BorderBrush = if ($Hovered) { Get-UiResource 'PrimaryGoldBrush' } else { Get-UiResource 'IronOuterBorderBrush' }
    $Card.BorderThickness = New-Object Windows.Thickness 2
    $item = $script:CardLookup[$FileName]
    if ($item) { $item.InnerBorder.Background = if ($Hovered) { Get-UiBrush '#15252C' } else { Get-UiResource 'TerrainCardBackgroundBrush' } }
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
    $card.Background = Get-UiBrush '#060A0C'
    $card.BorderBrush = Get-UiResource 'IronOuterBorderBrush'
    $card.BorderThickness = New-Object Windows.Thickness 2
    $card.CornerRadius = New-Object Windows.CornerRadius 5
    $card.Cursor = [Windows.Input.Cursors]::Hand
    $card.Tag = [string]$Terrain.file

    $innerBorder = New-Object Windows.Controls.Border
    $innerBorder.Margin = New-Object Windows.Thickness 1
    $innerBorder.Background = Get-UiResource 'TerrainCardBackgroundBrush'
    $innerBorder.BorderBrush = Get-UiResource 'GoldBorderBrush'
    $innerBorder.BorderThickness = New-Object Windows.Thickness 1
    $innerBorder.CornerRadius = New-Object Windows.CornerRadius 3
    $innerBorder.ClipToBounds = $true

    $grid = New-Object Windows.Controls.Grid
    foreach ($height in @(144, 39, 29)) {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = New-Object Windows.GridLength $height
        [void]$grid.RowDefinitions.Add($row)
    }

    $imageBorder = New-Object Windows.Controls.Border
    $imageBorder.Background = Get-UiBrush '#080D10'
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
    $name.Foreground = Get-UiResource 'PrimaryTextBrush'
    $name.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $name.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $name.TextAlignment = [Windows.TextAlignment]::Center
    $name.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    [Windows.Controls.Grid]::SetRow($name, 1)
    [void]$grid.Children.Add($name)

    $badge = New-Object Windows.Controls.Border
    $badge.Margin = New-Object Windows.Thickness 52, 2, 52, 4
    $badge.CornerRadius = New-Object Windows.CornerRadius 3
    $badge.Visibility = [Windows.Visibility]::Collapsed
    $badgeText = New-Object Windows.Controls.TextBlock
    $badgeText.Foreground = Get-UiResource 'PrimaryTextBrush'
    $badgeText.FontSize = 12
    $badgeText.FontWeight = [Windows.FontWeights]::SemiBold
    $badgeText.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $badgeText.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $badge.Child = $badgeText
    [Windows.Controls.Grid]::SetRow($badge, 2)
    [void]$grid.Children.Add($badge)

    $innerBorder.Child = $grid
    $card.Child = $innerBorder
    $card.Add_MouseEnter({ param($sender, $eventArgs) Set-CardHover -Card $sender -FileName ([string]$sender.Tag) -Hovered $true })
    $card.Add_MouseLeave({ param($sender, $eventArgs) Set-CardHover -Card $sender -FileName ([string]$sender.Tag) -Hovered $false })
    $card.Add_MouseLeftButtonUp({ param($sender, $eventArgs) Invoke-TerrainCardClick -FileName ([string]$sender.Tag) })
    $script:CardLookup[[string]$Terrain.file] = [pscustomobject]@{ File = [string]$Terrain.file; Card = $card; InnerBorder = $innerBorder; Badge = $badge; BadgeText = $badgeText; NameText = $name }
    [void]$ui.TerrainPanel.Children.Add($card)
}

function Show-OperationError([string]$Message) {
    [void](Show-AppDialog -Title $text.operationFailedTitle -Message $Message -PrimaryText '确定' -Kind Error)
}

function Show-AppDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$PrimaryText,
        [string]$SecondaryText,
        [switch]$ShowDoNotShow,
        [string]$CodeExample,
        [ValidateSet('Normal','Success','Warning','Error')][string]$Kind = 'Normal'
    )
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    if ($window.IsVisible) { $dialog.Owner = $window }
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dialog.SizeToContent = [Windows.SizeToContent]::WidthAndHeight
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
    $dialog.Background = Get-UiBrush '#05090B'
    $dialog.Foreground = Get-UiResource 'PrimaryTextBrush'
    $dialog.FontFamily = New-Object Windows.Media.FontFamily 'Microsoft YaHei UI'
    if ($window.Icon) { $dialog.Icon = $window.Icon }

    $outer = New-Object Windows.Controls.Border
    $outer.Width = 620
    $outer.MaxHeight = 780
    $outer.Margin = New-Object Windows.Thickness 8
    $outer.Padding = New-Object Windows.Thickness 3
    $outer.Background = Get-UiBrush '#05090B'
    $outer.BorderThickness = New-Object Windows.Thickness 3
    $outer.BorderBrush = switch ($Kind) {
        'Error' { Get-UiResource 'ErrorBorderBrush' }
        'Warning' { Get-UiResource 'WarningBorderBrush' }
        'Success' { Get-UiBrush '#496B39' }
        default { Get-UiResource 'IronInnerBorderBrush' }
    }
    $shadow = New-Object Windows.Media.Effects.DropShadowEffect
    $shadow.Color = [Windows.Media.Colors]::Black
    $shadow.BlurRadius = 14
    $shadow.Opacity = 0.48
    $shadow.ShadowDepth = 4
    $outer.Effect = $shadow

    $inner = New-Object Windows.Controls.Border
    $inner.Background = Get-UiResource 'PanelBackgroundBrush'
    $inner.BorderBrush = Get-UiResource 'GoldBorderBrush'
    $inner.BorderThickness = New-Object Windows.Thickness 1
    $inner.Padding = New-Object Windows.Thickness 22,18,22,20
    $outer.Child = $inner

    $root = New-Object Windows.Controls.Grid
    foreach ($height in @('Auto','Auto','*','Auto')) {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = if ($height -eq '*') { New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto }
        [void]$root.RowDefinitions.Add($row)
    }

    $titleBlock = New-Object Windows.Controls.TextBlock
    $titleBlock.Text = $Title
    $titleBlock.Foreground = Get-UiResource 'PrimaryGoldBrush'
    $titleBlock.FontSize = 20
    $titleBlock.FontWeight = [Windows.FontWeights]::SemiBold
    [Windows.Controls.Grid]::SetRow($titleBlock, 0)
    [void]$root.Children.Add($titleBlock)

    $separator = New-Object Windows.Controls.Border
    $separator.Height = 1
    $separator.Margin = New-Object Windows.Thickness 0,12,0,14
    $separator.Background = Get-UiResource 'GoldBorderBrush'
    [Windows.Controls.Grid]::SetRow($separator, 1)
    [void]$root.Children.Add($separator)

    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.MaxHeight = 550
    $scroll.VerticalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
    $body = New-Object Windows.Controls.StackPanel
    $messageBlock = New-Object Windows.Controls.TextBlock
    $messageBlock.Text = $Message
    $messageBlock.Foreground = Get-UiResource 'PrimaryTextBrush'
    $messageBlock.FontSize = 14
    $messageBlock.LineHeight = 23
    $messageBlock.TextWrapping = [Windows.TextWrapping]::Wrap
    [void]$body.Children.Add($messageBlock)

    if (-not [string]::IsNullOrWhiteSpace($CodeExample)) {
        $exampleBorder = New-Object Windows.Controls.Border
        $exampleBorder.Margin = New-Object Windows.Thickness 0,16,0,0
        $exampleBorder.Padding = New-Object Windows.Thickness 13,11,13,11
        $exampleBorder.Background = Get-UiBrush '#070C0F'
        $exampleBorder.BorderBrush = Get-UiResource 'GoldBorderBrush'
        $exampleBorder.BorderThickness = New-Object Windows.Thickness 1
        $exampleText = New-Object Windows.Controls.TextBlock
        $exampleText.Text = $CodeExample
        $exampleText.Foreground = Get-UiBrush '#D8D1BF'
        $exampleText.FontFamily = New-Object Windows.Media.FontFamily 'Consolas'
        $exampleText.FontSize = 13
        $exampleText.LineHeight = 20
        $exampleText.TextWrapping = [Windows.TextWrapping]::Wrap
        $exampleBorder.Child = $exampleText
        [void]$body.Children.Add($exampleBorder)
    }

    $scroll.Content = $body
    [Windows.Controls.Grid]::SetRow($scroll, 2)
    [void]$root.Children.Add($scroll)

    $checkBox = $null
    $footer = New-Object Windows.Controls.Grid
    $footer.Margin = New-Object Windows.Thickness 0,18,0,0
    [void]$footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
    $buttonColumn = New-Object Windows.Controls.ColumnDefinition
    $buttonColumn.Width = [Windows.GridLength]::Auto
    [void]$footer.ColumnDefinitions.Add($buttonColumn)
    if ($ShowDoNotShow) {
        $checkBox = New-Object Windows.Controls.CheckBox
        $checkBox.Content = '不再提示'
        $checkBox.Style = Get-UiResource 'RtsCheckboxStyle'
        $checkBox.FontSize = 14
        $checkBox.VerticalAlignment = [Windows.VerticalAlignment]::Center
        [Windows.Controls.Grid]::SetColumn($checkBox, 0)
        [void]$footer.Children.Add($checkBox)
    }

    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    [Windows.Controls.Grid]::SetColumn($buttons, 1)
    if (-not [string]::IsNullOrWhiteSpace($SecondaryText)) {
        $secondary = New-Object Windows.Controls.Button
        $secondary.Content = $SecondaryText
        $secondary.Style = Get-UiResource 'RtsSecondaryButtonStyle'
        $secondary.MinWidth = 112
        $secondary.Height = 38
        $secondary.Margin = New-Object Windows.Thickness 0,0,10,0
        $secondary.Add_Click({ $dialog.Tag = 'Secondary'; $dialog.Close() })
        [void]$buttons.Children.Add($secondary)
    }
    $primary = New-Object Windows.Controls.Button
    $primary.Content = $PrimaryText
    $primary.Style = Get-UiResource 'RtsPrimaryButtonStyle'
    $primary.MinWidth = 112
    $primary.Height = 38
    $primary.Add_Click({ $dialog.Tag = 'Primary'; $dialog.Close() })
    [void]$buttons.Children.Add($primary)
    [void]$footer.Children.Add($buttons)
    [Windows.Controls.Grid]::SetRow($footer, 3)
    [void]$root.Children.Add($footer)
    $inner.Child = $root
    $dialog.Content = $outer
    if (-not [string]::IsNullOrWhiteSpace($script:DialogSnapshotPath)) {
        $dialog.Add_ContentRendered({
            [void](Save-VisualSnapshot -Visual $dialog -Path $script:DialogSnapshotPath -Dpi $script:DialogSnapshotDpi)
            $dialog.Tag = 'Secondary'
            $dialog.Close()
        })
    }
    if ($window.IsVisible) { $ui.DialogOverlay.Visibility = [Windows.Visibility]::Visible }
    try { [void]$dialog.ShowDialog() } finally { $ui.DialogOverlay.Visibility = [Windows.Visibility]::Collapsed }
    return [pscustomobject]@{
        action    = if ($dialog.Tag) { [string]$dialog.Tag } else { 'Secondary' }
        doNotShow = [bool]($checkBox -and $checkBox.IsChecked)
    }
}

function Get-LiveTerrainSession {
    try {
        $session = Get-TerrainSession
        if ($session -and (Test-TerrainSessionProcess $session)) { return $session }
    } catch { }
    return $null
}

function Test-NormalModeBlocked {
    $session = Get-LiveTerrainSession
    if (-not $session) { return $false }
    return [string]$session.sessionId -ne [string]$script:TerrainSessionId
}

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
                $foreignOwnedState = ($state.PSObject.Properties.Name -contains 'sessionId') -and
                    -not [string]::IsNullOrWhiteSpace([string]$state.sessionId) -and
                    [string]$state.sessionId -ne [string]$script:TerrainSessionId
                if (-not $foreignOwnedState) {
                    $state.ownedName = $correctOwnedName
                    $state.targetName = $correctTargetName
                    Write-ActiveSwapState $state
                }
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
        if ($script:CurrentSessionOwner -ne 'Normal' -or [string]::IsNullOrWhiteSpace($script:TerrainSessionId)) {
            throw $text.otherSessionBlocksNormal
        }
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) { throw $text.gameRunningRestore }
        [void](Restore-ActiveSwap -ExpectedOwner Normal -ExpectedSessionId $script:TerrainSessionId)
        Clear-TerrainSession -ExpectedSessionId $script:TerrainSessionId
        Exit-TerrainOperationLock
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
    $firstNormalSwap = $false
    $pendingSessionId = $null
    try {
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) { throw $text.gameRunningSwap }
        if ($script:CurrentSessionOwner -ne 'Normal') {
            if (-not (Enter-TerrainOperationLock)) { throw $text.otherSessionBlocksNormal }
            $firstNormalSwap = $true
            $pendingSessionId = [guid]::NewGuid().ToString('N')
            $staleSession = Get-TerrainSession
            if ($staleSession) {
                if (Test-TerrainSessionProcess $staleSession) { throw $text.otherSessionBlocksNormal }
                Clear-TerrainSession
            }
            $orphanedState = Get-ActiveSwapState
            if ($orphanedState) { [void](Restore-ActiveSwap) }
        } else {
            $pendingSessionId = $script:TerrainSessionId
        }
        [void](Invoke-ManagedTerrainSwitch -MapsDirectory $script:CurrentMaps -OwnedFile $owned.file -TargetFile $target.file -OwnedName $owned.zh -TargetName $target.zh -Owner Normal -SessionId $pendingSessionId)
        if ($firstNormalSwap) { [void](Start-TerrainSession -Owner Normal -SessionId $pendingSessionId) }
        Write-SelectionPreferences -OwnedFile $owned.file -TargetFile $target.file -MapsDirectory $script:CurrentMaps
        Sync-SelectionFromState
    } catch {
        if ($firstNormalSwap -and $script:CurrentSessionOwner -ne 'Normal') {
            try {
                $failedState = Get-ActiveSwapState
                if ($failedState -and [string]$failedState.owner -eq 'Normal' -and [string]$failedState.sessionId -eq $pendingSessionId) {
                    [void](Restore-ActiveSwap -ExpectedOwner Normal -ExpectedSessionId $pendingSessionId)
                }
            } catch { }
            Exit-TerrainOperationLock
        }
        Sync-SelectionFromState -KeepOwnedWhenEmpty
        Show-OperationError $_.Exception.Message
    } finally {
        $window.Cursor = [Windows.Input.Cursors]::Arrow
        $script:IsBusy = $false
    }
}

function Invoke-AutoTerrainCardClick {
    param([Parameter(Mandatory)][string]$FileName)
    if ($script:IsBusy -or -not $script:CatalogLookup.ContainsKey($FileName)) { return }
    $previousOwnedFile = $script:AutoSelectedOwnedFile
    $previousTargetFile = $script:AutoSelectedTargetFile
    if ([string]::IsNullOrWhiteSpace($script:AutoSelectedOwnedFile)) {
        $script:AutoSelectedOwnedFile = $FileName
        $script:AutoSelectedTargetFile = $null
    } elseif ($FileName -eq $script:AutoSelectedOwnedFile) {
        $script:AutoSelectedOwnedFile = $null
        $script:AutoSelectedTargetFile = $null
    } else {
        $script:AutoSelectedTargetFile = $FileName
    }
    Update-CardVisuals
    if ([string]::IsNullOrWhiteSpace($script:AutoSelectedOwnedFile) -or [string]::IsNullOrWhiteSpace($script:AutoSelectedTargetFile)) { return }

    try {
        $owned = $script:CatalogLookup[$script:AutoSelectedOwnedFile]
        $target = $script:CatalogLookup[$script:AutoSelectedTargetFile]
        $previousConfig = Get-AutoModeConfig
        $selectionChanged = [string]$previousConfig.ownedTerrain -ne [string]$owned.id -or
            [string]$previousConfig.terrain -ne [string]$target.id
        $script:AutoConfig = Set-AutoModeTerrainSelection -OwnedTerrain ([string]$owned.id) -Terrain ([string]$target.id) -MapsDirectory $script:CurrentMaps
        if ($selectionChanged) { $script:AutoSelectionChangedThisRun = $true }
        [void](Update-AutoConfigVisuals -Config $script:AutoConfig)
        Show-AutoSelectionSavedStatus
    } catch {
        $script:AutoSelectedOwnedFile = $previousOwnedFile
        $script:AutoSelectedTargetFile = $previousTargetFile
        Update-CardVisuals
        Show-OperationError ('自动地图选择保存失败，已恢复原选择。' + $_.Exception.Message)
    }
}

function Invoke-TerrainCardClick {
    param([Parameter(Mandatory)][string]$FileName)
    if ($script:CurrentUiMode -eq 'Auto') {
        Invoke-AutoTerrainCardClick -FileName $FileName
        return
    }
    Invoke-NormalTerrainCardClick -FileName $FileName
}

function Invoke-NormalTerrainCardClick {
    param([Parameter(Mandatory)][string]$FileName)
    if ($script:IsBusy -or -not $script:CatalogLookup.ContainsKey($FileName)) { return }
    if (Test-NormalModeBlocked) {
        $session = Get-LiveTerrainSession
        Show-OperationError $(if ($session -and [string]$session.owner -eq 'Auto') { $text.autoSessionBlocksNormal } else { $text.otherSessionBlocksNormal })
        return
    }
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

function Get-CatalogFileById {
    param([string]$TerrainId)
    $terrain = Get-CatalogTerrainById -Catalog $script:Catalog -Id $TerrainId
    return $(if ($terrain) { [string]$terrain.file } else { $null })
}

function Update-AutoConfigVisuals {
    param([Parameter(Mandatory)]$Config)
    $ui.ActivateAutoButton.Content = if ($Config.enabled) { '●  自动替换已开启' } else { '开启自动替换' }
    $autoButtonStyle = if ($Config.enabled) {
        'RtsStatusButtonStyle'
    } elseif ($script:AutoSelectionChangedThisRun) {
        'RtsAttentionButtonStyle'
    } else {
        'RtsPrimaryButtonStyle'
    }
    $ui.ActivateAutoButton.Style = Get-UiResource $autoButtonStyle
    $ui.ActivateAutoButton.IsEnabled = $true
    $ui.ActivateAutoButton.IsHitTestVisible = -not [bool]$Config.enabled
    $ui.CancelAutoButton.IsEnabled = [bool]$Config.enabled
    $moved = -not [string]::IsNullOrWhiteSpace([string]$Config.launcherPath) -and
        -not [string]::IsNullOrWhiteSpace($script:ExecutablePath) -and
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Config.launcherPath), [System.IO.Path]::GetFullPath($script:ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)
    return $moved
}

function Read-AutoConfigForUi {
    try { return Get-AutoModeConfig } catch {
        Show-OperationError $_.Exception.Message
        return [pscustomobject]@{ version=1; enabled=$false; ownedTerrain=$null; terrain=$null; mapsDirectory=$null; launcherPath=$null; updatedAt=$null }
    }
}

$script:AutoConfig = Read-AutoConfigForUi
$script:AutoSelectedOwnedFile = Get-CatalogFileById ([string]$script:AutoConfig.ownedTerrain)
$script:AutoSelectedTargetFile = Get-CatalogFileById ([string]$script:AutoConfig.terrain)
$script:LauncherPathMoved = [bool](Update-AutoConfigVisuals -Config $script:AutoConfig)

function Show-CopySuccessStatus {
    if ($script:AutoSelectionChangedThisRun -and -not $script:AutoConfig.enabled) {
        $ui.CopyStatusBorder.Background = Get-UiBrush '#2A2112'
        $ui.CopyStatusBorder.BorderBrush = Get-UiResource 'WarningBorderBrush'
        $ui.CopyStatusText.Foreground = Get-UiBrush '#F0C957'
        $ui.CopyStatusText.Text = 'Steam 启动参数已复制，但自动替换尚未开启。请点击上方“开启自动替换”。'
    } else {
        $ui.CopyStatusBorder.Background = Get-UiBrush '#12261A'
        $ui.CopyStatusBorder.BorderBrush = Get-UiBrush '#607B3C'
        $ui.CopyStatusText.Foreground = Get-UiBrush '#9DD57B'
        $ui.CopyStatusText.Text = 'Steam 启动参数已复制。粘贴位置：Steam 客户端 → 库 → 右键 Dota 2 → 属性 → 通用 → 启动选项'
    }
    $ui.CopyStatusBorder.Visibility = [Windows.Visibility]::Visible
}

function Show-AutoSelectionSavedStatus {
    if ($script:AutoConfig.enabled) {
        $ui.CopyStatusBorder.Background = Get-UiBrush '#12261A'
        $ui.CopyStatusBorder.BorderBrush = Get-UiBrush '#607B3C'
        $ui.CopyStatusText.Foreground = Get-UiBrush '#9DD57B'
        $ui.CopyStatusText.Text = '新地图已自动保存，将从下一次 Steam 启动 Dota 2 起生效。'
    } else {
        $ui.CopyStatusBorder.Background = Get-UiBrush '#2A2112'
        $ui.CopyStatusBorder.BorderBrush = Get-UiResource 'WarningBorderBrush'
        $ui.CopyStatusText.Foreground = Get-UiBrush '#F0C957'
        $ui.CopyStatusText.Text = '地图选择已保存，但自动替换尚未开启。请点击上方“开启自动替换”。'
    }
    $ui.CopyStatusBorder.Visibility = [Windows.Visibility]::Visible
}

$ui.CopyStatusCloseButton.Add_Click({ $ui.CopyStatusBorder.Visibility = [Windows.Visibility]::Collapsed })

function Copy-SteamLaunchOption {
    try {
        $launchOption = Get-SteamLaunchOption
        [System.Windows.Clipboard]::SetText($launchOption)
        $config = Get-AutoModeConfig
        $config.launcherPath = [System.IO.Path]::GetFullPath($script:ExecutablePath)
        $script:AutoConfig = Save-AutoModeConfig -Config $config
        [void](Update-AutoConfigVisuals -Config $script:AutoConfig)
        Show-CopySuccessStatus
        return $true
    } catch {
        Show-OperationError ("复制 Steam 启动参数失败，请手动复制。`r`n`r`n$($_.Exception.Message)")
        return $false
    }
}

function Enable-AutoModeForUi {
    if ([string]::IsNullOrWhiteSpace($script:AutoSelectedOwnedFile) -or [string]::IsNullOrWhiteSpace($script:AutoSelectedTargetFile)) {
        throw '请先选择您已经拥有的地图和需要替换的目标地图。'
    }
    if ($script:AutoSelectedOwnedFile -eq $script:AutoSelectedTargetFile) { throw '已拥有地图和目标地图不能相同。' }
    $owned = $script:CatalogLookup[$script:AutoSelectedOwnedFile]
    $target = $script:CatalogLookup[$script:AutoSelectedTargetFile]
    if (-not $owned -or -not $target) { throw 'Terrain catalog mismatch：自动地图配置不在白名单中。' }
    if (-not $script:CurrentMaps -and -not (Initialize-DotaInstallation)) { return $false }
    if (-not (Test-VpkFile (Join-Path $script:CurrentMaps ([string]$owned.file)))) { throw '选择的源地图文件不存在，请重新选择。' }
    if (-not (Test-VpkFile (Join-Path $script:CurrentMaps ([string]$target.file)))) { throw '选择的目标地图文件不存在，请验证 Dota 2 游戏文件。' }
    try {
        $script:AutoConfig = Get-AutoModeConfig
        if ([string]$script:AutoConfig.ownedTerrain -ne [string]$owned.id -or [string]$script:AutoConfig.terrain -ne [string]$target.id) {
            throw '当前地图选择尚未成功保存，请重新选择。'
        }
        $script:AutoConfig.enabled = $true
        $script:AutoConfig.mapsDirectory = $script:CurrentMaps
        $script:AutoConfig = Save-AutoModeConfig -Config $script:AutoConfig
    } catch { throw ('自动替换开关保存失败，未开启自动替换。' + $_.Exception.Message) }
    $script:AutoSelectionChangedThisRun = $false
    [void](Update-AutoConfigVisuals -Config $script:AutoConfig)
    Show-AutoSelectionSavedStatus
    return $true
}

function Show-AutoActivationSuccessDialog {
    $activationMessage = @'
自动替换已开启。地图选择会在点击地图卡片时自动保存，无需再次确认。

请将本软件提供的启动参数粘贴到：
Steam 客户端 → 库 → 右键 Dota 2 → 属性 → 通用 → 启动选项

已有的 Dota 2 启动参数请保留在 %command% 后面，不要删除或覆盖。

配置完成后，本软件可以关闭。以后从 Steam 启动 Dota 2 时，程序会自动完成地图替换，并在 Dota 2 退出后恢复原地图。之后正常使用时无需再次手动打开本软件。

如需停止自动替换，可打开本软件点击“关闭自动替换”，或删除 Steam 启动选项中的本工具启动参数。
'@
        $steamExample = @'
启动选项示例

原来：
-perfectworld

改成：
"C:\...\Dota2MapSwitcher.exe" --auto %command% -perfectworld
'@
    $result = Show-AppDialog -Title '自动替换已开启' -Message $activationMessage -CodeExample $steamExample -PrimaryText '复制 Steam 启动参数' -SecondaryText '知道了' -Kind Success
    if ($result.action -eq 'Primary') { [void](Copy-SteamLaunchOption) }
}

$ui.ActivateAutoButton.Add_Click({
    try {
        if (Enable-AutoModeForUi) { Show-AutoActivationSuccessDialog }
    } catch { Show-OperationError $_.Exception.Message }
})

$ui.CancelAutoButton.Add_Click({
    try {
        $config = Get-AutoModeConfig
        $config.enabled = $false
        $script:AutoConfig = Save-AutoModeConfig -Config $config
        $script:AutoSelectionChangedThisRun = $false
        [void](Update-AutoConfigVisuals -Config $script:AutoConfig)
        [void](Show-AppDialog -Title '自动替换已关闭' -Message '已保存的地图选择仍然保留。即使 Steam 启动参数尚未删除，Dota 2 也会正常启动且不会修改地图。' -PrimaryText '知道了' -Kind Success)
    } catch { Show-OperationError $_.Exception.Message }
})

$ui.CopyLaunchButton.Add_Click({ [void](Copy-SteamLaunchOption) })

function Show-ModeGuide {
    param([Parameter(Mandatory)][ValidateSet('Normal','Auto')][string]$Mode)
    if ($Mode -eq 'Normal') {
        if ($script:NormalGuideShownThisRun -or -not $script:UiSettings.showNormalModeGuide) { return }
        $script:NormalGuideShownThisRun = $true
        $normalGuideMessage = @'
1. 选择您已经拥有的地图

2. 选择需要被替换的目标地图

3. 替换完成后请保持程序运行
'@
        $result = Show-AppDialog -Title '普通模式使用方法' -Message $normalGuideMessage -PrimaryText '知道了' -ShowDoNotShow
        if ($result.doNotShow) {
            try { $script:UiSettings.showNormalModeGuide = $false; $script:UiSettings = Save-UiSettings $script:UiSettings } catch { Show-OperationError $_.Exception.Message }
        }
        return
    }
    if ($script:AutoGuideShownThisRun -or -not $script:UiSettings.showAutoModeGuide) { return }
    $script:AutoGuideShownThisRun = $true
    $autoGuideMessage = @'
1. 选择您已经拥有的地图

2. 选择需要被替换的目标地图

3. 点击“开启自动替换”

地图选择会在点击卡片后自动保存；开启状态只控制 Steam 启动游戏时是否执行替换。

4. 点击“复制 Steam 启动参数”，并将其添加到 Dota 2 的 Steam 启动选项中。

如果已经存在 -perfectworld、-novid、-console 等参数，请保留这些参数，并放在 %command% 后面。

5. 配置完成后即可关闭本软件
'@
    $steamExample = @'
启动选项示例

原来：
-perfectworld

改成：
"C:\...\Dota2MapSwitcher.exe" --auto %command% -perfectworld
'@
    $result = Show-AppDialog -Title '自动替换模式使用方法' -Message $autoGuideMessage -CodeExample $steamExample -PrimaryText '知道了' -ShowDoNotShow
    if ($result.doNotShow) {
        try { $script:UiSettings.showAutoModeGuide = $false; $script:UiSettings = Save-UiSettings $script:UiSettings } catch { Show-OperationError $_.Exception.Message }
    }
}

$ui.ResetTutorialButton.Add_Click({
    try {
        $resetSettings = [pscustomobject]@{
            showNormalModeGuide       = $true
            showAutoModeGuide         = $true
            showNormalModeExitWarning = [bool]$script:UiSettings.showNormalModeExitWarning
        }
        $script:UiSettings = Save-UiSettings $resetSettings
        $script:NormalGuideShownThisRun = $false
        $script:AutoGuideShownThisRun = $false
        Show-ModeGuide -Mode $script:CurrentUiMode
    } catch {
        Show-OperationError ('重置教程失败。' + $_.Exception.Message)
    }
})

function Show-TerrainMode {
    param([Parameter(Mandatory)][ValidateSet('Normal','Auto')][string]$Mode)
    $script:CurrentUiMode = $Mode
    $ui.ModeSelectionPage.Visibility = [Windows.Visibility]::Collapsed
    $ui.TerrainPage.Visibility = [Windows.Visibility]::Visible
    $ui.AutoActionsPanel.Visibility = if ($Mode -eq 'Auto') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $ui.TitleText.Text = $text.windowTitle + $(if ($Mode -eq 'Auto') { ' · 自动替换模式' } else { ' · 普通模式' })
    if ($Mode -eq 'Auto') {
        $script:AutoConfig = Read-AutoConfigForUi
        $script:AutoSelectedOwnedFile = Get-CatalogFileById ([string]$script:AutoConfig.ownedTerrain)
        $script:AutoSelectedTargetFile = Get-CatalogFileById ([string]$script:AutoConfig.terrain)
        [void](Update-AutoConfigVisuals -Config $script:AutoConfig)
    } else {
        Sync-SelectionFromState -KeepOwnedWhenEmpty
    }
    Update-CardVisuals
    Show-ModeGuide -Mode $Mode
    if ($Mode -eq 'Normal' -and -not $script:NormalModeInitialized) {
        $script:NormalModeInitialized = $true
        $installationReady = [bool](Initialize-DotaInstallation)
        if ($installationReady -and -not $script:RecoveredCrashState -and -not $script:ForeignSessionActive) {
            Restore-RememberedSelection -AllowAutomaticTarget
        }
    }
}

function Show-ModeSelection {
    $script:CurrentUiMode = $null
    $ui.TerrainPage.Visibility = [Windows.Visibility]::Collapsed
    $ui.ModeSelectionPage.Visibility = [Windows.Visibility]::Visible
    $ui.TitleText.Text = $text.windowTitle
}

$ui.NormalModeChoice.Add_Checked({ $ui.NextButton.IsEnabled = $true })
$ui.AutoModeChoice.Add_Checked({ $ui.NextButton.IsEnabled = $true })
$ui.NextButton.Add_Click({
    if ($ui.NormalModeChoice.IsChecked) { Show-TerrainMode -Mode Normal }
    elseif ($ui.AutoModeChoice.IsChecked) { Show-TerrainMode -Mode Auto }
})
$ui.BackButton.Add_Click({
    if ($script:IsBusy) { return }
    if ($script:CurrentUiMode -eq 'Normal') {
        try { $state = Get-ActiveSwapState } catch { Show-OperationError ($text.stateInvalid -f $_.Exception.Message); return }
        if ($state -and [string]$state.owner -eq 'Normal' -and [string]$state.sessionId -eq [string]$script:TerrainSessionId) {
            $result = Show-AppDialog -Title '返回模式选择' -Message "当前存在正在使用的地图替换。`r`n`r`n返回上一步将恢复原地图。`r`n`r`n是否继续？" -PrimaryText '恢复并返回' -SecondaryText '取消'
            if ($result.action -ne 'Primary') { return }
            Invoke-CardRestore
            if (Get-ActiveSwapState) { return }
        }
    }
    Show-ModeSelection
})

if (-not [string]::IsNullOrWhiteSpace($UiSnapshotPath)) {
    $window.Show()
    $isAutoSnapshot = $UiSnapshotKind -in @('Auto','AutoGuide','AutoActivated')
    $isNormalSnapshot = $UiSnapshotKind -in @('Normal','NormalGuide','NormalExit','Error')
    if ($isAutoSnapshot -or $isNormalSnapshot) {
        $script:CurrentUiMode = if ($isAutoSnapshot) { 'Auto' } else { 'Normal' }
        $ui.ModeSelectionPage.Visibility = [Windows.Visibility]::Collapsed
        $ui.TerrainPage.Visibility = [Windows.Visibility]::Visible
        $ui.AutoActionsPanel.Visibility = if ($isAutoSnapshot) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $ui.TitleText.Text = $text.windowTitle + $(if ($isAutoSnapshot) { ' · 自动替换模式' } else { ' · 普通模式' })
        if ($isAutoSnapshot) {
            $script:AutoSelectedOwnedFile = 'dota_ti10.vpk'
            $script:AutoSelectedTargetFile = 'dota_cavern.vpk'
            [void](Update-AutoConfigVisuals -Config ([pscustomobject]@{ enabled=$true; launcherPath=$script:ExecutablePath }))
        } else {
            $script:SelectedOwnedFile = 'dota_ti10.vpk'
            $script:SelectedTargetFile = 'dota_cavern.vpk'
        }
        Update-CardVisuals
    }

    $dialogKind = $UiSnapshotKind -in @('NormalGuide','NormalExit','AutoGuide','AutoActivated','Error')
    if ($dialogKind) {
        $script:DialogSnapshotPath = [System.IO.Path]::GetFullPath($UiSnapshotPath)
        $script:DialogSnapshotDpi = $UiSnapshotDpi
        switch ($UiSnapshotKind) {
            'NormalGuide' {
                [void](Show-AppDialog -Title '普通模式使用方法' -Message "1. 选择您已经拥有的地图`r`n`r`n2. 选择需要被替换的目标地图`r`n`r`n3. 替换完成后请保持程序运行" -PrimaryText '知道了' -ShowDoNotShow)
            }
            'NormalExit' {
                [void](Show-AppDialog -Title '关闭程序' -Message "关闭窗口将恢复当前已替换的地图。`r`n`r`n是否继续关闭？" -PrimaryText '关闭并恢复' -SecondaryText '保持打开' -ShowDoNotShow -Kind Warning)
            }
            'AutoGuide' {
                $message = @'
1. 选择您已经拥有的地图

2. 选择需要被替换的目标地图

3. 点击“开启自动替换”

地图选择会在点击卡片后自动保存；开启状态只控制 Steam 启动游戏时是否执行替换。

4. 复制 Steam 启动参数，并将已有参数保留在 %command% 后面。

5. 配置完成后即可关闭本软件
'@
                $example = "启动选项示例`r`n`r`n原来：`r`n-perfectworld`r`n`r`n改成：`r`n`"C:\...\Dota2MapSwitcher.exe`" --auto %command% -perfectworld"
                [void](Show-AppDialog -Title '自动替换模式使用方法' -Message $message -CodeExample $example -PrimaryText '知道了' -ShowDoNotShow)
            }
            'AutoActivated' {
                $message = "自动替换已开启。地图选择会在点击卡片时自动保存。`r`n`r`n请将启动参数添加到 Dota 2 的 Steam 启动选项中。`r`n`r`n配置完成后，本软件可以关闭。"
                $example = "启动选项示例`r`n`r`n原来：`r`n-perfectworld`r`n`r`n改成：`r`n`"C:\...\Dota2MapSwitcher.exe`" --auto %command% -perfectworld"
                [void](Show-AppDialog -Title '自动替换已开启' -Message $message -CodeExample $example -PrimaryText '复制 Steam 启动参数' -SecondaryText '知道了' -Kind Success)
            }
            'Error' {
                [void](Show-AppDialog -Title '操作失败' -Message "未找到有效的 Dota 2 安装目录。`r`n`r`n请检查 Steam Library 路径后重试。" -PrimaryText '确定' -Kind Error)
            }
        }
        $script:DialogSnapshotPath = $null
    } else {
        [void](Save-VisualSnapshot -Visual $window -Path $UiSnapshotPath -Dpi $UiSnapshotDpi)
    }
    $window.Close()
    Write-Output ('UI SNAPSHOT SAVED: ' + [System.IO.Path]::GetFullPath($UiSnapshotPath))
    return
}

if ($UiSmokeTest) {
    foreach ($name in $uiNames) {
        if (-not $ui[$name]) { throw ('Missing map control: ' + $name) }
    }
    if ($script:CardLookup.Count -ne 11) { throw "Expected 11 terrain cards, found $($script:CardLookup.Count)." }
    if ($ui.NextButton.IsEnabled -or $ui.ModeSelectionPage.Visibility -ne [Windows.Visibility]::Visible) { throw 'Mode selection startup state test failed.' }
    if ($window.FindName('ModeTabs') -or $window.FindName('AutoOwnedCombo') -or $window.FindName('AutoTerrainCombo')) { throw 'Legacy tab/combo mode controls are still present.' }
    if ($window.FindName('SwapButton') -or $window.FindName('RestoreButton') -or $window.FindName('PathBox')) { throw 'Legacy controls are still visible.' }
    $script:AutoSelectionChangedThisRun = $true
    $smokeAutoConfig = [pscustomobject]@{ enabled=$false; launcherPath=$null }
    [void](Update-AutoConfigVisuals -Config $smokeAutoConfig)
    Show-AutoSelectionSavedStatus
    if ($ui.ActivateAutoButton.Style -ne (Get-UiResource 'RtsAttentionButtonStyle') -or $ui.CopyStatusText.Text -notmatch '尚未开启' -or
        $ui.CopyStatusBorder.Visibility -ne [Windows.Visibility]::Visible) {
        throw 'Inactive automatic-mode reminder visual test failed.'
    }
    $ui.CopyStatusCloseButton.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
    if ($ui.CopyStatusBorder.Visibility -ne [Windows.Visibility]::Collapsed) { throw 'Reminder close button test failed.' }
    Write-Output ('UI SMOKE TEST PASSED: two-step mode page; image cards=11; title=' + $window.Title)
    $window.Close()
    return
}

$script:RecoveredCrashState = $false
if (-not $UiCloseTest) {
    try {
        $leftoverState = Get-ActiveSwapState
        if ($leftoverState) {
            $liveSession = $null
            try {
                $savedSession = Get-TerrainSession
                if ($savedSession -and (Test-TerrainSessionProcess $savedSession)) { $liveSession = $savedSession }
            } catch { }
            if ($liveSession) {
                $script:ForeignSessionActive = $true
            } elseif (-not (Enter-TerrainOperationLock)) {
                $script:ForeignSessionActive = $true
            } else {
                try {
                    if (Test-Path -LiteralPath $script:TerrainSessionPath -PathType Leaf) { Clear-TerrainSession }
                    if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) {
                        [void](Show-AppDialog -Title $text.crashRecoveryTitle -Message $text.crashRecoveryGameRunning -PrimaryText '知道了' -Kind Warning)
                        return
                    }
                    # Recovery is a second swap of the same two filenames. It assumes the files
                    # were not externally reset after the state was written. If Steam 'Verify
                    # integrity' was used to restore the VPKs, clear the stale active-swap state
                    # before launching this tool again, otherwise this recovery would swap them again.
                    [void](Restore-ActiveSwap)
                    $script:RecoveredCrashState = $true
                } finally { Exit-TerrainOperationLock }
            }
        }
    } catch {
        [void](Show-AppDialog -Title $text.crashRecoveryTitle -Message ($text.crashRecoveryFailed -f $_.Exception.Message) -PrimaryText '知道了' -Kind Error)
        return
    }
}
if ($UiCrashRecoveryTest) { return }

Sync-SelectionFromState
$startupState = Get-ActiveSwapState
if ($startupState -and $script:ForeignSessionActive) {
    Restore-RememberedSelection
} elseif (-not $startupState) {
    Restore-RememberedSelection
}
$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:AllowWindowClose) { return }
    if ($script:IsBusy) {
        $eventArgs.Cancel = $true
        return
    }
    try {
        if ($script:AutoSelectionChangedThisRun) {
            $latestAutoConfig = Get-AutoModeConfig
            if (-not $latestAutoConfig.enabled) {
                $activationReminder = Show-AppDialog -Title '自动替换尚未开启' -Message "本次选择的自动替换地图已经保存，但自动替换开关仍处于关闭状态。`r`n`r`n如果现在关闭，下次从 Steam 启动 Dota 2 时不会替换地图。是否现在开启？" -PrimaryText '立即开启' -SecondaryText '暂不开启并关闭' -Kind Warning
                if ($activationReminder.action -eq 'Primary') {
                    if (-not (Enable-AutoModeForUi)) {
                        $eventArgs.Cancel = $true
                        return
                    }
                    Show-AutoActivationSuccessDialog
                } else {
                    $script:AutoSelectionChangedThisRun = $false
                    [void](Update-AutoConfigVisuals -Config $latestAutoConfig)
                }
            }
        }
        $state = Get-ActiveSwapState
        if (-not $state) {
            $script:AllowWindowClose = $true
            return
        }
        if ($script:CurrentSessionOwner -ne 'Normal' -or [string]$state.owner -ne 'Normal' -or [string]$state.sessionId -ne $script:TerrainSessionId) {
            $script:AllowWindowClose = $true
            return
        }
        $eventArgs.Cancel = $true
        if ($script:UiSettings.showNormalModeExitWarning) {
            $result = Show-AppDialog -Title '关闭程序' -Message "关闭窗口将恢复当前已替换的地图。`r`n`r`n是否继续关闭？" -PrimaryText '关闭并恢复' -SecondaryText '保持打开' -ShowDoNotShow
            if ($result.action -ne 'Primary') { return }
            if ($result.doNotShow) {
                try {
                    $script:UiSettings.showNormalModeExitWarning = $false
                    $script:UiSettings = Save-UiSettings $script:UiSettings
                } catch {
                    Show-OperationError $_.Exception.Message
                    return
                }
            }
        }
        if (Get-Process -Name dota2 -ErrorAction SilentlyContinue) {
            [void](Show-AppDialog -Title $text.closeRestoreFailedTitle -Message $text.closeWhileGameRunning -PrimaryText '知道了' -Kind Warning)
            return
        }
        $script:IsBusy = $true
        $window.Cursor = [Windows.Input.Cursors]::Wait
        [void](Restore-ActiveSwap -ExpectedOwner Normal -ExpectedSessionId $script:TerrainSessionId)
        Clear-TerrainSession -ExpectedSessionId $script:TerrainSessionId
        Exit-TerrainOperationLock
        $script:SelectedTargetFile = $null
        Update-CardVisuals
        $script:AllowWindowClose = $true
        $eventArgs.Cancel = $false
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
$window.Add_Closed({
    if ($script:SessionTimer) { $script:SessionTimer.Stop() }
})
if ($script:LauncherPathMoved) {
    [void](Show-AppDialog -Title '启动参数路径已变化' -Message '检测到本程序的目录或文件路径已经变化。请进入“自动替换模式”重新复制 Steam 启动参数。普通模式不受影响。' -PrimaryText '知道了' -Kind Warning)
}
[void]$window.ShowDialog()
Exit-TerrainOperationLock
