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

function Update-PlainCopy([string]$AppId, [string]$SourceDir) {
    <#
    Keep a plain, browsable copy of the CURRENT saves beside the repository.

    The repository holds every point in history and is the thing worth having,
    but reading it needs git. Someone whose PC died, sitting at a new machine
    with nothing but their synced folder, should be able to open it and see
    save files. So the current state is also written out as ordinary files,
    named by game. History still lives in the repository next to it.

    Only for a folder destination: an online backup is a URL, not something you
    can browse.
    #>
    $origin = Get-GitLine @('remote', 'get-url', 'origin')
    if (-not $origin -or $origin -notmatch '\.git$') { return }
    if ($origin -match '^[a-z]+://' -or $origin -match '^[^\\/:]+@') { return }   # remote URL
    $folder = Split-Path $origin -Parent
    if (-not $folder -or -not (Test-Path $folder)) { return }

    try {
        $dest = Join-Path (Join-Path $folder 'Your saves (latest)') (Split-Path (Get-GameBranchRoot $AppId) -Leaf)
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item (Join-Path $SourceDir '*') $dest -Recurse -Force
    } catch {
        Write-Capture "[warn] plain copy: $_"
    }
}

function Set-FolderLabel([string]$Dir, [string]$Label) {
    <#
    Make Explorer show the game name for a folder that is really called
    "1683340".

    The folder cannot be renamed: that path is inside every commit's tree, so
    renaming it would fragment history. But Explorer displays
    LocalizedResourceName from a desktop.ini instead of the real folder name,
    which puts the game on screen while the appid stays on disk where git needs
    it. Cosmetic only, and gitignored so it never reaches a commit.

    desktop.ini is honoured only when it is hidden+system AND the folder itself
    is read-only or system. Both are set here. Neither breaks wipe-and-recopy,
    because Remove-Item -Force clears read-only.
    #>
    if (-not $Label) { return }
    try {
        $ini  = Join-Path $Dir 'desktop.ini'
        $text = "[.ShellClassInfo]`r`nLocalizedResourceName=$Label`r`nInfoTip=Steam save timeline for $Label`r`n"
        Set-Content -LiteralPath $ini -Value $text -Encoding Unicode -Force
        (Get-Item -LiteralPath $ini -Force).Attributes =
            [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Archive
        $folder = Get-Item -LiteralPath $Dir -Force
        $folder.Attributes = $folder.Attributes -bor [IO.FileAttributes]::ReadOnly
    } catch {
        # cosmetic only: never let this stop a snapshot
    }
}

function Write-GamesIndex([hashtable]$Names) {
    <#
    The same map, written for a person rather than a parser.

    Steam identifies a game only by number, and the mirror's folders are named
    that way because that path is inside every commit's tree; renaming it would
    fragment history. So the number stays and this sits beside it. Open the
    mirror, or clone the second copy onto a bare machine, and you can tell which
    game is which without running anything or searching for the id online.
    #>
    $rows = @()
    foreach ($ref in @(Get-GitOutput @('for-each-ref', '--format=%(refname:short)', 'refs/heads/game/*/main'))) {
        $ref = ([string]$ref).Trim()
        if (-not $ref) { continue }
        $root  = $ref.Substring(0, $ref.LastIndexOf('/'))
        $appId = ($root -split '-')[-1]
        if ($appId -notmatch '^\d+$') { $appId = ($root -split '/')[-1] }
        $name  = if ($Names.ContainsKey($appId)) { [string]$Names[$appId] } else { "app $appId" }
        $rows += [pscustomobject]@{ Name = $name; AppId = $appId; Root = $root }
    }

    $md  = @('# Games in this timeline', '')
    $md += 'Written by the watcher. Steam identifies a game only by its App ID, which is'
    $md += 'also what the folders in here are called. This maps them back to something'
    $md += 'readable.'
    $md += ''
    $md += '| Game | App ID | Folder | Timeline |'
    $md += '| --- | --- | --- | --- |'
    foreach ($r in ($rows | Sort-Object Name)) {
        $md += "| $($r.Name) | $($r.AppId) | ``$($r.AppId)/`` | ``$($r.Root)/main`` |"
    }
    $md += ''
    $md += 'To pull one file back by hand: find the game above, then'
    $md += ''
    $md += '    git log <timeline>'
    $md += '    git checkout <commit> -- <appid>/remote/<file>'
    ($md -join "`r`n") | Set-Content (Join-Path $script:CapMirror 'GAMES.md') -Encoding UTF8
}

function Find-AdjacentBackup {
    <#
    A backup sitting next to these files.

    The recovery story is: new PC, sign in to OneDrive or Google Drive, find
    the folder, drop the release zip into it and run setup. No instructions
    about copying things out of the synced folder first, no git knowledge, no
    paths to type. If a bare repository is beside us, that is a backup, and we
    offer to pick it up.

    The scripts can happily live in the synced folder. What must NOT is the
    working mirror: a live git working tree inside a syncing folder is how you
    get conflict copies of git internals. So a restore clones the backup to the
    local mirror path and points the second copy back at the folder it came
    from, which is the normal arrangement anyway.
    #>
    param([string]$Root = $PSScriptRoot)

    if (-not $Root) { return $null }
    foreach ($candidate in @(
            (Join-Path $Root 'steam-save-history.git'),
            (Join-Path (Split-Path $Root -Parent) 'steam-save-history.git'))) {
        if (-not (Test-Path (Join-Path $candidate 'objects'))) { continue }
        $games = @(& git --git-dir=$candidate branch --list 'game/*/main' 2>$null).Count
        if ($games -eq 0) { continue }
        $when = (& git --git-dir=$candidate for-each-ref --sort=-committerdate --count=1 --format='%(committerdate:short)' refs/heads 2>$null | Select-Object -First 1)
        return @{ Path = $candidate; Games = $games; Updated = $when }
    }
    return $null
}

function Restore-FromBackup([string]$BackupRepo, [string]$Destination) {
    <#
    Clone a found backup into the working mirror, then keep pushing back to it.
    A plain clone only creates a local branch for HEAD, so every game timeline
    is recreated from its remote-tracking ref or the mirror would look empty.
    #>
    # git writes ordinary chatter to stderr ("No such remote: origin" when there
    # is nothing to remove), and under EAP Stop that becomes a terminating
    # error. Judge git by its exit code here, same as Invoke-Git does.
    $ErrorActionPreference = 'Continue'

    Write-Capture "[restore] reading $BackupRepo"
    if (Test-Path (Join-Path $Destination '.git')) {
        # An empty timeline is already here, which happens when the watcher
        # started before anyone opened setup. Wire it up and fetch rather than
        # refusing, so the backup is still picked up.
        if (@(& git -C $Destination branch --list 'game/*/main').Count -gt 0) {
            throw "$Destination already holds timelines"
        }
        & git -C $Destination remote remove origin 2>&1 | Out-Null
        & git -C $Destination remote add origin $BackupRepo 2>&1 | Out-Null
        & git -C $Destination fetch --quiet origin 2>&1 | Out-Null
    } else {
        & git clone --quiet -- $BackupRepo $Destination 2>&1 | Out-Null
    }
    if (-not (Test-Path (Join-Path $Destination '.git'))) { throw 'could not read that backup' }

    $made = 0
    foreach ($ref in @(& git -C $Destination for-each-ref --format='%(refname:short)' refs/remotes/origin)) {
        $ref = ([string]$ref).Trim()
        if (-not $ref -or $ref -eq 'origin/HEAD') { continue }
        $local = $ref -replace '^origin/', ''
        & git -C $Destination show-ref --verify --quiet "refs/heads/$local" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { continue }     # HEAD's branch already exists
        & git -C $Destination branch --quiet $local $ref 2>&1 | Out-Null
        $made++
    }
    $total = @(& git -C $Destination branch --list).Count
    Write-Capture "[restore] $total timeline(s) recovered, $made recreated from the backup"
    return $total
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
    # Explorer's folder labels are local decoration, not history.
    $gi = Join-Path $script:CapMirror '.gitignore'
    if (-not (Test-Path $gi)) {
        "# Explorer folder labels, cosmetic and machine-local.`ndesktop.ini`n" |
            Set-Content $gi -Encoding ASCII -NoNewline
    }
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

    # Explorer shows "Kayak VR: Mirage (1683340)"; the folder is still 1683340.
    Set-FolderLabel $dest "$name ($appId)"

    # [appid] prefix kept as a readable anchor; a timeline is one game's branch,
    # so history no longer has to be grepped out of a shared log.
    $commit = New-AppCommit $appId $Branch "[$appId] ${name}: $verb at $stamp$note"
    if (-not $commit) { return $null }                            # nothing changed
    Write-Capture "[$verb] $name ($appId) -> $Branch$note"

    if ((Invoke-Git @('remote', 'get-url', 'origin')) -eq 0) {
        if ((Invoke-Git @('push', 'origin', $Branch)) -ne 0) { Write-Capture '[warn] push failed' }
        Update-PlainCopy $appId $dest
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
    Write-GamesIndex $Names
    Save-Metadata | Out-Null
    return $caches.Count
}
