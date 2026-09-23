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

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'steam_save_settings.ps1')
. (Join-Path $PSScriptRoot 'steam_save_capture.ps1')

# Config comes from settings.json beside the scripts, so the mirror path cannot
# disagree between this, the setup window and the browser.
<#
Everything this process says goes to a file, because nothing it says reaches a
person otherwise. It is launched through run-hidden.vbs, which creates no
console at all, so `[error] snapshot ...`, `[warn] push failed` and even a
startup crash have been going nowhere. Someone would find out months later by
opening the browser and noticing a game stopped at an old date.

Not in the mirror (a git working tree) and not beside the scripts (which may be
inside OneDrive): LOCALAPPDATA.
#>
$script:LogPath = Join-Path $env:LOCALAPPDATA 'Steam Save Timeline\watcher.log'
function Write-Log([string]$Message) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message
    try {
        $dir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Roll at a megabyte, keeping one previous file. Small enough to read,
        # long enough to cover the gap before anyone thinks to look.
        if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 1MB) {
            Move-Item $script:LogPath "$($script:LogPath).1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
    Write-Host $line
}

$cfg                = Get-SteamSaveSettings
$MirrorDir          = $cfg.MirrorDir
$DebounceSeconds    = $cfg.DebounceSeconds
$DailySnapshotHours = $cfg.DailySnapshotHours

Set-CaptureLogger { param($Message) Write-Log $Message }   # also routes steam_save_timelines.ps1
Initialize-Capture $MirrorDir

<#
One watcher per mirror. Three were found running at once on the dev machine,
and two of them racing produced an empty save point and a commit carrying
another game's files. The snapshot lock now prevents that corruption, but a
second watcher is still pure waste: duplicate sweeps, duplicate pushes, and
every snapshot queueing behind another process doing the same work.

Held for the life of the process. Deliberately not released anywhere: when this
exits, by any route, Windows drops it.
#>
# Only the resident watcher is exclusive. `-Once` is a one-shot sweep, which is
# exactly what the tray's "Snapshot everything now" runs while the daemon is up,
# so blocking it here made that menu item do nothing at all. Its writes are
# still serialised, by the per-mirror snapshot lock rather than by this.
$script:InstanceLock = $null
if (-not $Once) {
    $lockName = 'SteamSaveTimelineWatcher-' + ([BitConverter]::ToString(
        [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($MirrorDir.ToLowerInvariant()))) -replace '-', '')
    try   { $script:InstanceLock = [System.Threading.Mutex]::new($false, "Global\$lockName") }
    catch { $script:InstanceLock = [System.Threading.Mutex]::new($false, $lockName) }
    $gotIt = $false
    try { $gotIt = $script:InstanceLock.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $gotIt = $true }
    if (-not $gotIt) {
        Write-Log "[exit] another watcher is already running for $MirrorDir"
        return
    }
}

$steamRoot = Find-SteamRoot
$userdata  = Join-Path $steamRoot 'userdata'
Initialize-Repo
$names = Get-GameNames $steamRoot
Write-GamesJson $names
Write-GamesIndex $names
Set-TimelineGameNames $names

# Branches carry the game name as well as the appid. Older mirrors used the
# appid alone; rename them in place (git branch -m keeps every commit).
$renamedRefs = Update-BranchNaming $names
$plainMoved = Update-PlainCopyNames   # the second copy's folders follow the refs
if ($renamedRefs -gt 0) { Write-Log "[init] renamed $renamedRefs branch(es) to include game names" }

# Give any game already mirrored under an older layout its own timeline.
# No-op once every game has one.
$seeded = Initialize-GameTimelines $names
if ($seeded -gt 0) { Write-Log "[init] created $seeded game timeline(s)" }

# Sweep at startup as well as daily, so a machine that was off for a week gets
# a snapshot immediately rather than up to a day later.
Write-Log "[sweep] $(Invoke-Sweep $names $steamRoot) game(s)"
$lastSweep = Get-Date

if ($Once) { return }

Write-Log "[watch] $userdata -> $MirrorDir"

# Thread-safe map: ledger path -> last change time (debounce)
$pending = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new()

# Ids we have already gone looking for a name for, so an id Steam has no name
# for is not rescanned on every single sync.
$triedNames = @{}

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
# Without this the watcher can go permanently deaf and still look alive. When
# the watched tree disappears (a library on a removable or network drive, a
# Steam reinstall, a drive letter change) the Error event fires and .NET sets
# EnableRaisingEvents to false. Nothing was subscribed, so nothing noticed and
# nothing re-armed: the process stayed up, kept holding the single-instance
# mutex so nothing else could take over, and never captured another sync. The
# poll loop below re-arms and sweeps to catch up.
Register-ObjectEvent $fsw Error -MessageData $pending -Action {
    $script:WatchError = $Event.SourceEventArgs.GetException().Message
} | Out-Null
$fsw.EnableRaisingEvents = $true

while ($true) {
    Start-Sleep -Seconds 3
    $now = Get-Date

    # Re-arm if the watch died. .NET clears this itself on an Error, and the
    # directory may well be back by now (drive reconnected, Steam reinstalled).
    # Sweep after re-arming, because everything that changed while deaf was
    # missed.
    if (-not $fsw.EnableRaisingEvents) {
        if ($script:WatchError) {
            Write-Log "[error] the ledger watch failed: $($script:WatchError)"
            $script:WatchError = $null
        }
        if (Test-Path $userdata) {
            try {
                $fsw.EnableRaisingEvents = $true
                Write-Log '[watch] re-armed after losing the ledger directory; sweeping to catch up'
                Write-Log "[sweep] $(Invoke-Sweep $names $steamRoot) game(s)"
                $lastSweep = $now
            } catch { Write-Log "[error] could not re-arm the watch: $_" }
        }
    }

    if (($now - $lastSweep).TotalHours -ge $DailySnapshotHours) {
        $lastSweep = $now
        try { Write-Log "[sweep] $(Invoke-Sweep $names $steamRoot) game(s)" }
        catch { Write-Log "[error] daily sweep: $_" }
    }

    foreach ($kv in $pending.GetEnumerator()) {
        if (($now - $kv.Value).TotalSeconds -lt $DebounceSeconds) { continue }
        $ignore = [datetime]::MinValue
        [void]$pending.TryRemove($kv.Key, [ref]$ignore)
        try {
            # A game installed after this process started is not in the cached
            # name map, so it would be captured as "app <appid>" and filed under
            # game/app-<appid>, which looks like the game was never captured at
            # all. Re-read the names once per unseen id, not every sync, since
            # a few ids (the Steam client itself, controller configs) have no
            # name to find and would otherwise rescan forever.
            $newId = Split-Path (Split-Path $kv.Key -Parent) -Leaf
            if ($names.Count -eq 0 -or
                (-not $names.ContainsKey($newId) -and -not $triedNames.ContainsKey($newId))) {
                $triedNames[$newId] = $true
                $names = Get-GameNames $steamRoot
                Set-TimelineGameNames $names
                if ($names.ContainsKey($newId)) {
                    Write-Log "[names] learned $($names[$newId]) ($newId)"
                    Write-GamesJson $names
                    Write-GamesIndex $names
                }
            }
            New-Snapshot $kv.Key $names $steamRoot | Out-Null
        } catch {
            Write-Log "[error] snapshot $($kv.Key): $_"
            # Put it back. The key is removed before the snapshot so a rewrite
            # during one is not lost, but that also meant a failure discarded
            # the event entirely and the sync waited for the daily sweep.
            $pending[$kv.Key] = Get-Date
        }
    }
}
