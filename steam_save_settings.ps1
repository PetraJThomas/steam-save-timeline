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

    $script:SettingsCache = [pscustomobject]@{
        MirrorDir          = [Environment]::ExpandEnvironmentVariables([string]$values.mirrorDir)
        DebounceSeconds    = [int]$values.debounceSeconds
        DailySnapshotHours = [double]$values.dailySnapshotHours
        TaskName           = [string]$values.taskName
        Path               = $path
    }
    return $script:SettingsCache
}
