<#
steam_save_watcher.ps1: git-backed timeline of Steam Cloud saves (Windows)

Watches every userdata\<userid>\<appid>\remotecache.vdf via .NET
FileSystemWatcher. That file is Steam's sync ledger, rewritten after every
cloud sync (upload OR download). On change: wait for the sync to settle, then
snapshot that game onto its active timeline.

Separately it sweeps every game onto its own daily timeline at startup and
every $DailySnapshotHours. A commit on a sync timeline means Steam actually
moved data; a commit on a daily timeline means "this is what was on disk at
time T". Keeping them apart keeps both meanings honest, and the sweep is the
floor of coverage if Steam never syncs.

The work itself lives in steam_save_capture.ps1; this script is the daemon
around it. Mirror layout and branch scheme are documented there and in
steam_save_timelines.ps1.

Run:  powershell -ExecutionPolicy Bypass -File steam_save_watcher.ps1
      ... -Once     sweep everything once and exit (no watching)

Set it up with steam_save_setup.ps1, which can register it to start at log on.
Requires git on PATH.
#>
param([switch]$Once)

# ---------------- config ----------------
$MirrorDir          = Join-Path $env:USERPROFILE 'steam-save-history'
$DebounceSeconds    = 15
$DailySnapshotHours = 24
# ----------------------------------------

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'steam_save_capture.ps1')
Initialize-Capture $MirrorDir

$steamRoot = Find-SteamRoot
$userdata  = Join-Path $steamRoot 'userdata'
Initialize-Repo
$names = Get-GameNames $steamRoot
Write-GamesJson $names
Set-TimelineGameNames $names

# Branches carry the game name as well as the appid. Older mirrors used the
# appid alone; rename them in place (git branch -m keeps every commit).
$renamedRefs = Update-BranchNaming $names
if ($renamedRefs -gt 0) { Write-Host "[init] renamed $renamedRefs branch(es) to include game names" }

# Give any game already mirrored under an older layout its own timeline.
# No-op once every game has one.
$seeded = Initialize-GameTimelines $names
if ($seeded -gt 0) { Write-Host "[init] created $seeded game timeline(s)" }

# Sweep at startup as well as daily, so a machine that was off for a week gets
# a snapshot immediately rather than up to a day later.
Write-Host "[sweep] $(Invoke-Sweep $names $steamRoot) game(s)"
$lastSweep = Get-Date

if ($Once) { return }

Write-Host "[watch] $userdata -> $MirrorDir"

# Thread-safe map: ledger path -> last change time (debounce)
$pending = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new()

# Steam names it remotecache.vdf; older clients wrote remotecache.vcf.
$fsw = [System.IO.FileSystemWatcher]::new($userdata, 'remotecache.v*')
$fsw.IncludeSubdirectories = $true
$fsw.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, FileName, Size'

$handler = {
    $path = $Event.SourceEventArgs.FullPath
    $Event.MessageData[$path] = Get-Date
}
Register-ObjectEvent $fsw Changed -MessageData $pending -Action $handler | Out-Null
Register-ObjectEvent $fsw Created -MessageData $pending -Action $handler | Out-Null
Register-ObjectEvent $fsw Renamed -MessageData $pending -Action $handler | Out-Null
$fsw.EnableRaisingEvents = $true

while ($true) {
    Start-Sleep -Seconds 3
    $now = Get-Date

    if (($now - $lastSweep).TotalHours -ge $DailySnapshotHours) {
        $lastSweep = $now
        try { Write-Host "[sweep] $(Invoke-Sweep $names $steamRoot) game(s)" }
        catch { Write-Host "[error] daily sweep: $_" }
    }

    foreach ($kv in $pending.GetEnumerator()) {
        if (($now - $kv.Value).TotalSeconds -lt $DebounceSeconds) { continue }
        $ignore = [datetime]::MinValue
        [void]$pending.TryRemove($kv.Key, [ref]$ignore)
        try {
            if ($names.Count -eq 0) { $names = Get-GameNames $steamRoot }
            New-Snapshot $kv.Key $names $steamRoot | Out-Null
        } catch {
            Write-Host "[error] snapshot $($kv.Key): $_"
        }
    }
}
