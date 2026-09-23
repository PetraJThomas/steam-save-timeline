<#
steam_save_timelines.ps1: save branches ("timelines") for the mirror repo.

Every branch holds exactly one game. That single rule is what makes save
branches work: git branches are repo-wide, but a save timeline is per-game, so
a shared branch would mean forking one game's timeline rolled back every other
game's mirror.

    game/<name>-<appid>/main    the canonical timeline for that game
    game/<name>-<appid>/daily   its daily snapshots, a floor of coverage that
                                does not depend on Steam ever syncing
    game/<name>-<appid>/<slug>  a save branch: a divergent playthrough
    master                      repo metadata (games.json, timelines.json)

e.g. game/kayak-vr-mirage-1683340/main. The name is there to be read; the
appid is what code matches on, because names change and refs cannot hold the
characters game titles use.

Exactly one timeline per game is *active*; the watcher appends new syncs to it.
The daily timeline is an archive and is never active, restoring from it lands
on whatever timeline you are actually playing.

Commits are built with a throwaway index (read-tree / write-tree / commit-tree /
update-ref) rather than `git checkout`, so a branch is extended without ever
being checked out and without disturbing any other game. A consequence: the
working tree is a staging area, not a meaningful checkout. `git status` in the
mirror is noise, read history with `git log game/<name>-<appid>/main`.

Dot-sourced by the watcher and the restore GUI. Call Initialize-Timelines first.
#>

$script:TLMirror = $null
$script:TLMeta   = $null
$script:TLLog       = { param($Message) Write-Host $Message }
$script:TLRootMoves = @()
$script:TLLock      = $null
$script:TLLockDepth = 0

function Set-TimelineLogger([scriptblock]$Logger) { $script:TLLog = $Logger }
# Out-Null because the logger is supplied by the caller: setup hands in one
# that writes to its progress panel, and any logger that RETURNS a value
# would otherwise leak it into the pipeline of whatever called this.
function Write-Timeline([string]$Message) { & $script:TLLog $Message | Out-Null }

# ---------------- one writer at a time ----------------

<#
The mirror has one working tree and one set of refs, and a commit is built by
staging files on disk. Two processes doing that at once corrupt each other:
not theoretical, two watchers running together produced both an empty commit
and a commit holding another game's files. A named mutex rather than a lock
file, so a process dying while holding it is reported rather than wedging
every later snapshot forever.
#>

function Get-TimelineLockName {
    # Named per mirror, so two mirrors never block each other. A mutex name
    # cannot contain a backslash, so the path is hashed rather than embedded.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = [BitConverter]::ToString(
            $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes(
                ([string]$script:TLMirror).ToLowerInvariant()))).Replace('-', '')
    } finally { $md5.Dispose() }
    return "SteamSaveTimeline-$hash"
}

function Enter-TimelineLock([int]$TimeoutSeconds = 180) {
    <#
    Returns $true when the lock is held. Re-entrant on the same thread, so a
    snapshot can take it once and the commit inside it can take it again.
    #>
    if ($script:TLLockDepth -gt 0) { $script:TLLockDepth++; return $true }

    if (-not $script:TLLock) {
        $name = Get-TimelineLockName
        # Global first, so a watcher running as a scheduled task in another
        # session still excludes one started from the tray. Not every context
        # is allowed to create a global mutex, hence the fallback.
        try   { $script:TLLock = [System.Threading.Mutex]::new($false, "Global\$name") }
        catch { $script:TLLock = [System.Threading.Mutex]::new($false, $name) }
    }

    $held = $false
    try {
        $held = $script:TLLock.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [System.Threading.AbandonedMutexException] {
        # The previous holder died mid-write. The lock is ours now, but the
        # mirror may have been left half-written, so say so out loud.
        Write-Timeline '[warn] a previous snapshot exited while writing; continuing'
        $held = $true
    }
    if (-not $held) {
        Write-Timeline "[warn] another snapshot held the mirror for over $TimeoutSeconds s; skipping this one"
        return $false
    }
    $script:TLLockDepth = 1
    return $true
}

function Exit-TimelineLock {
    if ($script:TLLockDepth -le 0) { return }
    $script:TLLockDepth--
    if ($script:TLLockDepth -eq 0 -and $script:TLLock) {
        try { $script:TLLock.ReleaseMutex() } catch { }
    }
}


function Initialize-Timelines([string]$MirrorDir) {
    if ($script:TLLock -and $script:TLMirror -ne $MirrorDir) {
        # The lock is named after the mirror, so pointing at a different one
        # means the old mutex no longer guards anything we care about.
        if ($script:TLLockDepth -gt 0) { try { $script:TLLock.ReleaseMutex() } catch { } }
        $script:TLLock.Dispose()
        $script:TLLock      = $null
        $script:TLLockDepth = 0
    }
    $script:TLMirror = $MirrorDir
    $script:TLMeta   = $null
}

function Invoke-Git([string[]]$GitArgs) {
    # git puts ordinary warnings on stderr; with EAP 'Stop' plus 2>&1 PowerShell
    # promotes those to terminating errors. Judge git by its exit code only.
    $ErrorActionPreference = 'Continue'
    & git -C $script:TLMirror @GitArgs 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Get-GitOutput([string[]]$GitArgs) {
    $ErrorActionPreference = 'Continue'
    & git -C $script:TLMirror @GitArgs 2>$null
}

function Get-GitLine([string[]]$GitArgs) {
    <#
    One line of output, or $null when git failed.

    The exit-code check is load-bearing, not tidiness. `git rev-parse` writes
    the argument it could not resolve to STDOUT and the `fatal:` to stderr,
    which Get-GitOutput discards, so asking for a path that does not exist used
    to hand back the literal string "master:timelines.json" -- truthy, and
    indistinguishable from a real hash.

    That made New-PathCommit's "which of these paths does the branch already
    know" filter answer "all of them", so a fresh mirror staged timelines.json
    before anything had created it, `git add` failed, and the whole metadata
    commit was abandoned. The second copy on a new install therefore never
    received games.json or GAMES.md: no appid-to-name map for the one person
    who most needs it, someone restoring onto a machine with nothing on it.
    #>
    $out = @(Get-GitOutput $GitArgs)
    if ($LASTEXITCODE -ne 0) { return $null }
    $v = $out | Select-Object -First 1
    if ($v) { return ([string]$v).Trim() }
    return $null
}

# ---------------- naming ----------------

function Get-MetaBranch {
    if (-not $script:TLMeta) {
        $b = Get-GitLine @('symbolic-ref', '--short', 'HEAD')
        if ($b) { $script:TLMeta = $b } else { $script:TLMeta = 'master' }
    }
    return $script:TLMeta
}

<#
Branch roots are `game/<slug>-<appid>`, so `git branch` reads as
`game/kayak-vr-mirage-1683340/main` instead of a wall of numbers, and sorts
alphabetically by game.

The appid stays, and stays authoritative. It is the only stable identity: Valve
renames games, and names carry colons, slashes and trademark signs that a ref
cannot. So the slug is a label for humans and the appid is what code matches
on. A game renamed later keeps its existing branch rather than being renamed
again, because the ref is found by appid, not by name.
#>
$script:GameNames  = @{}
$script:RootCache  = @{}

function Set-TimelineGameNames([hashtable]$Names) {
    if ($Names) { $script:GameNames = $Names }
    $script:RootCache = @{}
}

function Get-GameSlug([string]$AppId) {
    $name = $null
    if ($script:GameNames -and $script:GameNames.ContainsKey($AppId)) { $name = [string]$script:GameNames[$AppId] }
    # unknown, or the "app 1683340" placeholder: do not end up with the id twice
    if (-not $name -or $name -match '^app\s+\d+$') { return 'app' }
    $slug = ConvertTo-TimelineSlug $name
    if (-not $slug -or $slug -eq 'timeline') { $slug = 'app' }
    return $slug
}

function Get-GameBranchRoot([string]$AppId) {
    <# The ref prefix for one game, reusing whatever already exists. #>
    if ($script:RootCache.ContainsKey($AppId)) { return $script:RootCache[$AppId] }

    foreach ($pattern in @("refs/heads/game/*-$AppId/*", "refs/heads/game/$AppId/*")) {
        $ref = Get-GitLine @('for-each-ref', '--format=%(refname:short)', '--count=1', $pattern)
        if ($ref) {
            $root = $ref.Substring(0, $ref.LastIndexOf('/'))
            $script:RootCache[$AppId] = $root
            return $root
        }
    }
    $root = "game/$(Get-GameSlug $AppId)-$AppId"
    $script:RootCache[$AppId] = $root
    return $root
}

function Get-MainTimeline ([string]$AppId) { return ((Get-GameBranchRoot $AppId) + '/main') }
function Get-DailyTimeline([string]$AppId) { return ((Get-GameBranchRoot $AppId) + '/daily') }

function ConvertTo-TimelineSlug([string]$Name) {
    # git refs forbid spaces, ~ ^ : ? * [ .. and a trailing .lock, so reduce a
    # user-typed name to something that is always a legal ref component.
    $s = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $s) { $s = 'timeline' }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    return $s
}

function Test-Timeline([string]$Branch) {
    if (-not $Branch) { return $false }
    return ((Invoke-Git @('show-ref', '--verify', '--quiet', "refs/heads/$Branch")) -eq 0)
}

function Get-TimelineLabel([string]$AppId, [string]$Branch) {
    $leaf = Split-Path $Branch -Leaf
    switch ($leaf) {
        'main'  { return 'main' }
        'daily' { return 'daily snapshots' }
        default { return $leaf }
    }
}

function Get-GameTimelines([string]$AppId) {
    <# main first, then save branches, then the daily archive. #>
    $active = Get-ActiveTimeline $AppId
    $main   = Get-MainTimeline $AppId
    $daily  = Get-DailyTimeline $AppId
    $out    = @()

    foreach ($b in @(Get-GitOutput @('for-each-ref', '--format=%(refname:short)', "refs/heads/$(Get-GameBranchRoot $AppId)/"))) {
        $b = ([string]$b).Trim()
        if (-not $b) { continue }
        $kind = 'fork'
        if ($b -eq $main)  { $kind = 'main' }
        if ($b -eq $daily) { $kind = 'daily' }
        $out += [pscustomobject]@{
            Branch   = $b
            Label    = (Get-TimelineLabel $AppId $b)
            Kind     = $kind
            IsActive = ($b -eq $active)
        }
    }
    $order = @{ 'main' = 0; 'fork' = 1; 'daily' = 2 }
    return @($out | Sort-Object @{ e = { $order[$_.Kind] } }, Label)
}

# ---------------- which timeline is live ----------------

function Get-TimelineMap {
    $p = Join-Path $script:TLMirror 'timelines.json'
    $m = @{}
    if (Test-Path $p) {
        try {
            (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $m[$_.Name] = [string]$_.Value }
        } catch {}
    }
    return $m
}

function Get-ActiveTimeline([string]$AppId) {
    $m = Get-TimelineMap
    if ($m.ContainsKey($AppId) -and $m[$AppId] -and (Test-Timeline $m[$AppId])) { return $m[$AppId] }
    return (Get-MainTimeline $AppId)   # also the fallback if a branch was deleted
}

function Set-ActiveTimeline([string]$AppId, [string]$Branch) {
    $m = Get-TimelineMap
    if ($Branch -eq (Get-MainTimeline $AppId)) { $m.Remove($AppId) | Out-Null }
    else { $m[$AppId] = $Branch }
    ($m | ConvertTo-Json) | Set-Content (Join-Path $script:TLMirror 'timelines.json') -Encoding UTF8
    Save-Metadata | Out-Null
}

function Save-Metadata {
    # games.json / timelines.json live on the metadata branch, not on any game's
    # timeline, they are repo-level and would otherwise churn every game's log.
    $commit = New-PathCommit @('games.json', 'GAMES.md', 'timelines.json', '.gitattributes', '.gitignore') (Get-MetaBranch) 'metadata'

    # Push it too. A snapshot only pushes the branch it just wrote, so without
    # this the second copy keeps every save but freezes its game names and its
    # record of which timeline is being played at whatever they were on day one.
    if ($commit -and (Invoke-Git @('remote', 'get-url', 'origin')) -eq 0) {
        Invoke-Git @('push', 'origin', (Get-MetaBranch)) | Out-Null
    }
    return $commit
}

# ---------------- commits without checkout ----------------

function New-PathCommit {
    <#
    Commit the working tree's $Paths onto $Branch without checking it out.
    A throwaway index seeded from $Branch means every other path in that branch
    is inherited byte-for-byte and nothing else in the repo is touched.
    Returns the new commit hash, or $null when nothing changed.
    #>
    param([string[]]$Paths, [string]$Branch, [string]$Message)

    # Unique per call. A fixed name was shared by every concurrent snapshot,
    # and one process deleting it between another's add and write-tree
    # silently yielded the empty tree, which then got committed.
    $idx = Join-Path $script:TLMirror ('.git\timeline-index-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N'))
    if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }

    if (-not (Enter-TimelineLock)) { return $null }

    # Inside the try from here: anything that throws between taking the lock and
    # entering it would never release it.
    try {
    $parent = $null
    if (Test-Timeline $Branch) { $parent = Get-GitLine @('rev-parse', $Branch) }

    $env:GIT_INDEX_FILE = $idx
        if ($parent) { if ((Invoke-Git @('read-tree', $Branch)) -ne 0) { return $null } }
        else         { if ((Invoke-Git @('read-tree', '--empty')) -ne 0) { return $null } }

        $present = @($Paths | Where-Object { Test-Path (Join-Path $script:TLMirror $_) })
        $known   = @($Paths | Where-Object { $parent -and (Get-GitLine @('rev-parse', "${Branch}:$_")) })
        $stage   = @(@($present + $known) | Select-Object -Unique)
        if ($stage.Count -eq 0) { return $null }
        if ((Invoke-Git (@('add', '-A', '--') + $stage)) -ne 0) { return $null }

        $tree = Get-GitLine @('write-tree')
        if (-not $tree) { return $null }

        # Every caller stages .gitattributes, so an empty tree cannot be a real
        # result. It means the index went missing underneath us. Committing it
        # would write a save point containing nothing at all.
        if ($tree -eq '4b825dc642cb6eb9a060e54bf8d69288fbee4904') {
            Write-Timeline "[warn] refusing an empty commit on $Branch; the index was lost mid-write"
            return $null
        }

        if ($parent) {
            if ($tree -eq (Get-GitLine @('rev-parse', "$Branch^{tree}"))) { return $null }   # nothing new
            $commit = Get-GitLine @('commit-tree', $tree, '-p', $parent, '-m', $Message)
        } else {
            $commit = Get-GitLine @('commit-tree', $tree, '-m', $Message)
        }
        if (-not $commit) { return $null }
        if ((Invoke-Git @('update-ref', "refs/heads/$Branch", $commit)) -ne 0) { return $null }
        return $commit
    } finally {
        Remove-Item env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }
        Exit-TimelineLock
    }
}

function New-AppCommit([string]$AppId, [string]$Branch, [string]$Message) {
    # .gitattributes rides along so a clone of this branch alone still stores
    # save data byte-exact.
    return (New-PathCommit @($AppId, '.gitattributes') $Branch $Message)
}

function Expand-AppTree([string]$AppId, [string]$Commit) {
    <#
    Materialise <appid>/ from $Commit into the working tree. The wipe matters:
    `git checkout <commit> -- <path>` does not delete files that exist now but
    not in that commit, which would otherwise smuggle extra files into a restore.
    #>
    # Held across the wipe as well as the checkout: a snapshot walking in
    # between the two would find the folder gone and stage the whole game
    # as deleted.
    if (-not (Enter-TimelineLock)) { return $false }

    # Everything after the lock lives in the try. The wipe used to sit outside
    # it, and a single open handle on a file in that folder (Explorer, an AV
    # scanner, a sync client) threw under the GUI's ErrorActionPreference of
    # Stop, so the lock was never released. The window looked fine while every
    # other process, the capture daemon included, stalled 180s per call and
    # then skipped, for as long as that window stayed open.
    $idx = Join-Path $script:TLMirror ('.git\timeline-checkout-index-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N'))
    try {
        # Ask before destroying. If the commit holds nothing for this game there
        # is no checkout to do, and wiping first would delete the folder for
        # nothing.
        if ((Invoke-Git @('cat-file', '-e', "${Commit}:$AppId")) -ne 0) { return $false }

        $dir = Join-Path $script:TLMirror $AppId
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction Stop }

        if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }
        $env:GIT_INDEX_FILE = $idx
        return ((Invoke-Git @('checkout', $Commit, '--', "$AppId/")) -eq 0)
    } catch {
        Write-Timeline "[warn] could not lay out $AppId from ${Commit}: $_"
        return $false
    } finally {
        Remove-Item env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }
        Exit-TimelineLock
    }
}

# ---------------- timeline operations ----------------

function Get-ForkPoint([string]$AppId, [string]$Branch) {
    # The last commit this timeline shared with main, "before you diverged".
    $main = Get-MainTimeline $AppId
    if ($Branch -eq $main -or -not (Test-Timeline $main)) { return $null }
    return (Get-GitLine @('merge-base', $Branch, $main))
}

function New-TimelineFork {
    <# Branch this game's timeline at $FromCommit and make the fork active. #>
    param([string]$AppId, [string]$Name, [string]$FromCommit)

    $slug = ConvertTo-TimelineSlug $Name
    if ($slug -in @('main', 'daily')) {
        return @{ Ok = $false; Message = "'$slug' is reserved, pick another name." }
    }
    $ref = (Get-GameBranchRoot $AppId) + "/$slug"
    if (Test-Timeline $ref) {
        return @{ Ok = $false; Message = "This game already has a timeline called '$slug'." }
    }
    if ((Invoke-Git @('branch', $ref, $FromCommit)) -ne 0) {
        return @{ Ok = $false; Message = 'git could not create that branch.' }
    }
    Set-ActiveTimeline $AppId $ref
    return @{ Ok = $true; Branch = $ref; Slug = $slug }
}

function Invoke-MakeCanonical {
    <#
    Put this timeline's current state onto the game's main timeline as a new
    commit, and go back to playing main. Deliberately a roll-forward and not a
    git merge: main's history is never rewritten, and the save branch is left
    intact in case it turns out to have been the better run after all.
    #>
    param([string]$AppId, [string]$Branch, [string]$GameName)

    $main = Get-MainTimeline $AppId
    if ($Branch -eq $main) { return @{ Ok = $false; Message = 'That is already the main timeline.' } }
    $tip = Get-GitLine @('rev-parse', $Branch)
    if (-not $tip) { return @{ Ok = $false; Message = 'That timeline has no commits.' } }

    # One lock across laying the tree out AND committing it. Taking it twice let
    # a capture land in between, overwrite the folder with live saves, and leave
    # New-AppCommit with nothing new to commit. It then returned Ok with no
    # commit and moved the player back to main, which did not hold the branch's
    # saves at all.
    if (-not (Enter-TimelineLock)) {
        return @{ Ok = $false; Message = 'The mirror was busy. Try again in a moment.' }
    }
    try {
        if (-not (Expand-AppTree $AppId $tip)) {
            return @{ Ok = $false; Message = 'Could not read that timeline out of git.' }
        }
        $label  = Get-TimelineLabel $AppId $Branch
        $commit = New-AppCommit $AppId $main "[$AppId] ${GameName}: CANONICAL from $label ($($tip.Substring(0,8)))"
        if (-not $commit) {
            # No commit is only legitimate when main already holds exactly this.
            # Otherwise something raced us, and saying "done" would be a lie.
            $same = (Get-GitLine @('rev-parse', "${main}^{tree}")) -eq (Get-GitLine @('rev-parse', "${tip}^{tree}"))
            if (-not $same) {
                return @{ Ok = $false; Message = 'Nothing was written: the mirror changed while this ran. Try again.' }
            }
        }
        Set-ActiveTimeline $AppId $main
        return @{ Ok = $true; Commit = $commit; Branch = $main; From = $label }
    } finally { Exit-TimelineLock }
}

function Get-LastSnapshotTime([string]$AppId, [string]$Branch) {
    if (-not (Test-Timeline $Branch)) { return $null }
    $d = Get-GitLine @('log', '-1', '--format=%aI', $Branch)
    if ($d) { try { return [datetime]$d } catch {} }
    return $null
}

function Get-LastRootMoves {
    <# (old root, new root) pairs from the most recent Update-BranchNaming. #>
    return $script:TLRootMoves
}

function Update-BranchNaming([hashtable]$Names) {
    <#
    Rename legacy `game/<appid>/*` refs to `game/<slug>-<appid>/*`. Idempotent:
    a root that is not bare digits is already named and is left alone, and a
    game renamed on Steam later keeps the ref it has rather than churning.

    `git branch -m` moves the ref and keeps every commit, so no history is
    touched. timelines.json is repointed in the same pass, since it stores
    branch names.
    #>
    Set-TimelineGameNames $Names
    $map        = Get-TimelineMap
    $mapChanged = $false
    $renamed    = 0
    $moved      = @()
    $script:TLRootMoves = @()

    foreach ($ref in @(Get-GitOutput @('for-each-ref', '--format=%(refname:short)', 'refs/heads/game/'))) {
        $ref = ([string]$ref).Trim()
        if (-not $ref) { continue }
        $parts = $ref -split '/'
        if ($parts.Count -ne 3) { continue }

        # Two shapes get healed. `game/<appid>/*` is the original layout. So is
        # `game/app-<appid>/*`, which happens when a game is captured before its
        # name is known: the capture is fine, but the game shows up in the
        # browser as "app 389140" and looks like it was never captured. Once a
        # real name exists, move it. A game Steam has no name for at all (the
        # client itself, controller configs) keeps `app` and is left alone,
        # rather than churning the ref on every startup.
        $appId = $null
        if     ($parts[1] -match '^\d+$')      { $appId = $parts[1] }
        elseif ($parts[1] -match '^app-(\d+)$') { $appId = $Matches[1] }
        else { continue }                                          # already named

        $slug = Get-GameSlug $appId
        if ($slug -eq 'app') { continue }                          # still nameless
        $new = "game/$slug-$appId/$($parts[2])"
        if ($new -eq $ref) { continue }
        if ((Invoke-Git @('branch', '-m', $ref, $new)) -ne 0) {
            <#
            `git branch -m` refuses when the target already exists, which means
            this game has ended up under two roots at once. That is reachable:
            a rename whose `push --delete` of the old name failed leaves the
            second copy holding both, and restoring from it brings both back.

            Silently giving up was the worst answer. Whichever root won the
            `for-each-ref` lookup became the game, and every commit under the
            other one stayed in the repo but vanished from the browser, with no
            warning and no later pass able to repair it.

            Park it under the correct root instead. Nothing is deleted, nothing
            is overwritten, and the orphaned history shows up in the browser as
            an extra timeline the person can look at and make canonical. Which
            of the two deserves to be `main` is their call, not ours.
            #>
            $parked = $null
            for ($i = 1; $i -le 50; $i++) {
                $try = "$new-recovered-$i"
                if (-not (Test-Timeline $try)) { $parked = $try; break }
            }
            if ($parked -and (Invoke-Git @('branch', '-m', $ref, $parked)) -eq 0) {
                Write-Timeline "[warn] $ref could not become $new because that already exists; kept as $parked so its history stays reachable"
                $renamed++
                $moved += ,@($ref, $parked)
            } else {
                Write-Timeline "[warn] $ref could not be renamed to $new and could not be parked; its history is only reachable with git"
            }
            continue
        }

        $renamed++
        $moved += ,@($ref, $new)
        foreach ($k in @($map.Keys)) {
            if ($map[$k] -eq $ref) { $map[$k] = $new; $mapChanged = $true }
        }
    }

    # A rename that stops at the local mirror leaves the second copy holding the
    # old name forever. Restoring from that backup then recreates both refs, so
    # one game arrives as two timelines, and the stale one still matches the
    # `game/*-<appid>/*` lookup. Carry the rename across: push the new name,
    # then drop the old. Best effort, because the backup may be offline, and a
    # failure here must never cost a capture.
    # Roots, not refs: anything named after a root (the plain second copy folders)
    # has to follow the rename too, or it is orphaned under the old name.
    $seen = @{}
    foreach ($pair in $moved) {
        $oldRoot = $pair[0].Substring(0, $pair[0].LastIndexOf('/'))
        $newRoot = $pair[1].Substring(0, $pair[1].LastIndexOf('/'))
        if ($oldRoot -eq $newRoot) { continue }
        $key = "$oldRoot->$newRoot"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $script:TLRootMoves += ,@($oldRoot, $newRoot)
    }

    if ($moved.Count -gt 0 -and (Invoke-Git @('remote', 'get-url', 'origin')) -eq 0) {
        foreach ($pair in $moved) {
            if ((Invoke-Git @('push', 'origin', $pair[1])) -ne 0) {
                Write-Timeline "[warn] could not push $($pair[1]) to the second copy"
                continue
            }
            if ((Invoke-Git @('push', 'origin', '--delete', $pair[0])) -ne 0) {
                # A delete "fails" when the old name was never pushed there in
                # the first place, which is the common case and not worth a
                # warning. Only say something if it really is still there.
                if (Get-GitLine @('ls-remote', '--heads', 'origin', $pair[0])) {
                    Write-Timeline "[warn] $($pair[0]) still exists in the second copy"
                }
            }
        }
    }

    if ($renamed -gt 0) {
        $script:RootCache = @{}
        if ($mapChanged) {
            ($map | ConvertTo-Json) | Set-Content (Join-Path $script:TLMirror 'timelines.json') -Encoding UTF8
        }
        Save-Metadata | Out-Null
    }
    return $renamed
}

function Initialize-GameTimelines([hashtable]$Names) {
    <#
    One-off: give every game already in the mirror its own main timeline. Safe
    to re-run, it only creates branches that do not exist yet.
    #>
    Set-TimelineGameNames $Names
    $made = 0
    foreach ($d in (Get-ChildItem $script:TLMirror -Directory | Where-Object { $_.Name -match '^\d+$' })) {
        $appId = $d.Name
        $main  = Get-MainTimeline $appId
        if (Test-Timeline $main) { continue }
        $name = if ($Names.ContainsKey($appId)) { $Names[$appId] } else { "app $appId" }
        if (New-AppCommit $appId $main "[$appId] ${name}: timeline created") { $made++ }
    }
    return $made
}
