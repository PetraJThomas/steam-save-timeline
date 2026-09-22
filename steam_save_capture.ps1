<#
steam_save_capture.ps1: taking a snapshot of one game, or of all of them.

Lifted out of the watcher so the setup window can run the very first sweep
through exactly the same code the daemon uses later. Nothing here loops or
waits; it captures when told to.

    Initialize-Capture <mirror dir>   once, before anything else
    New-Snapshot  <ledger> <names> <steam root> [<branch>] [sync|snapshot]
    Invoke-Sweep  <names> <steam root>

Progress goes through Set-CaptureLogger, so the same functions can write to a
console or into a window.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'steam_save_roots.ps1')
. (Join-Path $PSScriptRoot 'steam_save_timelines.ps1')   # also supplies Invoke-Git

$script:CapMirror = $null
$script:CapLog    = { param($Message) Write-Host $Message }

function Initialize-Capture([string]$MirrorDir) {
    $script:CapMirror = $MirrorDir
    Initialize-Timelines $MirrorDir
}

function Set-CaptureLogger([scriptblock]$Logger) { $script:CapLog = $Logger }
function Write-Capture([string]$Message) { & $script:CapLog $Message }

function Write-GamesJson([hashtable]$Names) {
    # appid -> name map at repo root, so the GUI never has to find Steam itself
    $Names | ConvertTo-Json | Set-Content (Join-Path $script:CapMirror 'games.json') -Encoding UTF8
}

function Initialize-Repo {
    New-Item -ItemType Directory -Path $script:CapMirror -Force | Out-Null
    if (-not (Test-Path (Join-Path $script:CapMirror '.git'))) {
        Invoke-Git @('init') | Out-Null
        Write-Capture "[init] created git repo at $($script:CapMirror)"
    }
    # Save files are opaque bytes. With the usual global core.autocrlf=true git
    # would rewrite every LF to CRLF on checkout, so a restored save would not
    # be the file Steam uploaded. Belt and braces: repo config plus an explicit
    # .gitattributes, since the config alone does not travel with a clone.
    Invoke-Git @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git @('config', 'core.safecrlf', 'false') | Out-Null
    $ga = Join-Path $script:CapMirror '.gitattributes'
    if (-not (Test-Path $ga)) {
        "# Save data is byte-exact: never translate line endings.`n* -text`n" |
            Set-Content $ga -Encoding ASCII -NoNewline
        Invoke-Git @('add', '--', '.gitattributes') | Out-Null
        Invoke-Git @('commit', '-m', 'Store save data byte-exact (no eol translation)') | Out-Null
    }
}

function Copy-ExternalRoots([string]$CachePath, [string]$Dest, [string]$SteamRoot) {
    <#
    Files with a non-zero root, copied per-entry straight out of the ledger, so
    nothing outside the listed paths is ever touched. Returns a small summary.
    #>
    $map     = @(Get-SaveFileMap -CachePath $CachePath -SteamRoot $SteamRoot) |
               Where-Object { $_.RootCode -ne 0 }
    $bases   = [ordered]@{}
    $copied  = 0
    $missing = 0
    $skipped = @()

    foreach ($f in $map) {
        if ($f.Unmapped) { $skipped += $f.RootCode; continue }
        $bases[$f.RootName] = $f.Base
        if ($f.Missing) { $missing++; continue }      # listed by Steam, not downloaded here
        try {
            $target = Join-Path $Dest $f.MirrorRel
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $f.Source -Destination $target -Force
            $copied++
        } catch {
            Write-Capture "[warn] could not copy $($f.Source): $_"
        }
    }

    # Provenance: where these files came from at capture time. Restore re-resolves
    # live (a game can move between libraries), but this is the record of truth.
    if ($bases.Count -gt 0) {
        $bases | ConvertTo-Json | Set-Content (Join-Path $Dest 'roots.json') -Encoding UTF8
    }
    if ($skipped.Count -gt 0) {
        Write-Capture ("[warn] unmapped root code(s) {0} - run steam_save_roots.ps1 -Report" -f (($skipped | Select-Object -Unique) -join ', '))
    }
    return [pscustomobject]@{ Copied = $copied; Missing = $missing; Skipped = $skipped.Count }
}

function New-Snapshot {
    <#
    Copy one game's current cloud files into the mirror, then commit them to
    $Branch. $Kind only changes the wording: a 'sync' commit means Steam
    actually moved data, a 'snapshot' means a sweep found this on disk at that
    moment. Keeping them on separate timelines keeps both meanings honest.
    #>
    param(
        [string]$CachePath,
        [hashtable]$Names,
        [string]$SteamRoot,
        [string]$Branch,
        [ValidateSet('sync', 'snapshot')] [string]$Kind = 'sync'
    )

    $appDir = Split-Path $CachePath -Parent
    $appId  = Split-Path $appDir -Leaf
    $dest   = Join-Path $script:CapMirror $appId
    if (-not $Branch) { $Branch = Get-ActiveTimeline $appId }

    # Mirror true state: wipe and recopy so deletions show up in git too.
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    # root 0, copy remote\ wholesale rather than per-ledger-entry, so files
    # Steam has written but not yet indexed are captured too.
    $remote = Join-Path $appDir 'remote'
    if (Test-Path $remote) { Copy-Item $remote (Join-Path $dest 'remote') -Recurse -Force }

    Copy-Item $CachePath (Join-Path $dest (Split-Path $CachePath -Leaf)) -Force

    # every other root. AppData, Documents, the game's install dir
    $ext = Copy-ExternalRoots $CachePath $dest $SteamRoot

    $name  = if ($Names.ContainsKey($appId)) { $Names[$appId] } else { "app $appId" }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $note  = if ($ext.Copied -gt 0) { " (+$($ext.Copied) external)" } else { '' }
    $verb  = if ($Kind -eq 'snapshot') { 'snapshot' } else { 'sync' }

    # [appid] prefix kept as a readable anchor; a timeline is one game's branch,
    # so history no longer has to be grepped out of a shared log.
    $commit = New-AppCommit $appId $Branch "[$appId] ${name}: $verb at $stamp$note"
    if (-not $commit) { return $null }                            # nothing changed
    Write-Capture "[$verb] $name ($appId) -> $Branch$note"

    if ((Invoke-Git @('remote', 'get-url', 'origin')) -eq 0) {
        if ((Invoke-Git @('push', 'origin', $Branch)) -ne 0) { Write-Capture '[warn] push failed' }
    }
    return $commit
}

function Invoke-Sweep {
    <#
    Snapshot every game onto its own daily timeline, regardless of whether Steam
    has synced. This is the floor of coverage: at worst you lose a day, even if
    Steam never restarts. A game with no main timeline yet is seeded there too,
    so every game has a canonical history from the moment it is first seen.

    -OnEachGame runs before each game, for progress reporting.
    #>
    param([hashtable]$Names, [string]$SteamRoot, [scriptblock]$OnEachGame)

    Set-TimelineGameNames $Names
    $caches = @(Get-RemoteCachePaths $SteamRoot)
    $n = 0
    foreach ($cache in $caches) {
        $appId = Split-Path (Split-Path $cache.FullName -Parent) -Leaf
        $n++
        if ($OnEachGame) {
            $label = if ($Names.ContainsKey($appId)) { $Names[$appId] } else { "app $appId" }
            & $OnEachGame $n $caches.Count $label
        }
        try {
            New-Snapshot $cache.FullName $Names $SteamRoot (Get-DailyTimeline $appId) 'snapshot' | Out-Null
            $main = Get-MainTimeline $appId
            if (-not (Test-Timeline $main)) {
                New-Snapshot $cache.FullName $Names $SteamRoot $main 'snapshot' | Out-Null
            }
        } catch {
            Write-Capture "[error] sweep $($cache.FullName): $_"
        }
    }
    Write-GamesJson $Names
    Save-Metadata | Out-Null
    return $caches.Count
}
