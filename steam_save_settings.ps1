<#
steam_save_settings.ps1: one place for the handful of things worth changing.

`$MirrorDir` was declared separately in the watcher, the setup window and the
browser. Three copies of a path that must agree is a bug waiting to happen, so
they all read it from here now.

settings.json lives beside the scripts, is created with defaults the first time
anything asks, and is gitignored so pulling an update never fights it. Values
may use environment variables, e.g. %USERPROFILE%.

Deliberately NOT in here: anything the system already knows. Whether the
scheduled task exists, whether a startup shortcut is there, which timeline is
active, where the second copy points. That is state, and state is read from
the thing itself, so a settings file can never disagree with reality. This
holds configuration only.
#>

$script:SettingsCache = $null

function Get-SteamSaveSettings {
    param([switch]$Reload)

    if ($script:SettingsCache -and -not $Reload) { return $script:SettingsCache }

    $defaults = [ordered]@{
        mirrorDir          = '%USERPROFILE%\steam-save-history'
        debounceSeconds    = 15
        dailySnapshotHours = 24
        taskName           = 'Steam Save Timeline'
    }

    $path   = Join-Path $PSScriptRoot 'settings.json'
    $values = [ordered]@{}
    foreach ($k in $defaults.Keys) { $values[$k] = $defaults[$k] }

    if (Test-Path $path) {
        try {
            $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                if ($values.Contains($p.Name)) { $values[$p.Name] = $p.Value }
            }
        } catch {
            # A malformed file must not stop capture. Defaults win, loudly.
            Write-Warning "settings.json could not be read, using defaults: $_"
        }
    } else {
        try { ($defaults | ConvertTo-Json) | Set-Content $path -Encoding UTF8 } catch {}
    }

    $script:RawSettings = $values

    # Per value, each falling back on its own. These casts used to sit outside
    # every guard, so `"debounceSeconds": "fifteen"` threw out of this function.
    # The watcher calls it at the top level with no try/catch and runs with no
    # console, so one typo in settings.json killed capture with no error
    # anywhere at all. A bad value is worth a warning, never the daemon.
    function Get-Setting($Values, $Defaults, $Key, $Cast) {
        try {
            $v = & $Cast $Values[$Key]
            if ($null -eq $v) { throw 'null' }
            return $v
        } catch {
            Write-Warning "settings.json: $Key is not usable ('$($Values[$Key])'), using $($Defaults[$Key])"
            return (& $Cast $Defaults[$Key])
        }
    }
    $mirror = Get-Setting $values $defaults 'mirrorDir' { param($x) [Environment]::ExpandEnvironmentVariables([string]$x) }
    if (-not ([string]$mirror).Trim()) {
        Write-Warning "settings.json: mirrorDir is empty, using $($defaults.mirrorDir)"
        $mirror = [Environment]::ExpandEnvironmentVariables([string]$defaults.mirrorDir)
    }
    $debounce = Get-Setting $values $defaults 'debounceSeconds'    { param($x) [int]$x }
    $daily    = Get-Setting $values $defaults 'dailySnapshotHours' { param($x) [double]$x }
    $task     = Get-Setting $values $defaults 'taskName'           { param($x) [string]$x }
    # Zero or negative debounce means snapshotting mid-sync, which is worse than
    # waiting for it to settle.
    if ($debounce -lt 1) {
        Write-Warning "settings.json: debounceSeconds must be at least 1, using $($defaults.debounceSeconds)"
        $debounce = [int]$defaults.debounceSeconds
    }
    if ($daily -le 0) { $daily = [double]$defaults.dailySnapshotHours }
    if (-not $task)   { $task  = [string]$defaults.taskName }

    $script:SettingsCache = [pscustomobject]@{
        MirrorDir          = ([string]$mirror).Trim()
        DebounceSeconds    = $debounce
        DailySnapshotHours = $daily
        TaskName           = $task
        Path               = $path
    }
    return $script:SettingsCache
}

function Set-SteamSaveSetting {
    <#
    Merge values into settings.json and reload. Keys not passed are left alone,
    so writing one setting never silently resets the others.
    #>
    param([hashtable]$Values)

    [void](Get-SteamSaveSettings)          # ensures the file and $script:RawSettings exist
    $merged = [ordered]@{}
    foreach ($k in $script:RawSettings.Keys) { $merged[$k] = $script:RawSettings[$k] }
    foreach ($k in $Values.Keys)             { $merged[$k] = $Values[$k] }

    ($merged | ConvertTo-Json) | Set-Content (Join-Path $PSScriptRoot 'settings.json') -Encoding UTF8
    return (Get-SteamSaveSettings -Reload)
}
