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

function Initialize-Timelines([string]$MirrorDir) {
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
    $v = @(Get-GitOutput $GitArgs) | Select-Object -First 1
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

    $idx = Join-Path $script:TLMirror '.git\timeline-index'
    if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }

    $parent = $null
    if (Test-Timeline $Branch) { $parent = Get-GitLine @('rev-parse', $Branch) }

    $env:GIT_INDEX_FILE = $idx
    try {
        if ($parent) { if ((Invoke-Git @('read-tree', $Branch)) -ne 0) { return $null } }
        else         { if ((Invoke-Git @('read-tree', '--empty')) -ne 0) { return $null } }

        $present = @($Paths | Where-Object { Test-Path (Join-Path $script:TLMirror $_) })
        $known   = @($Paths | Where-Object { $parent -and (Get-GitLine @('rev-parse', "${Branch}:$_")) })
        $stage   = @(@($present + $known) | Select-Object -Unique)
        if ($stage.Count -eq 0) { return $null }
        if ((Invoke-Git (@('add', '-A', '--') + $stage)) -ne 0) { return $null }

        $tree = Get-GitLine @('write-tree')
        if (-not $tree) { return $null }

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
    $dir = Join-Path $script:TLMirror $AppId
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }

    $idx = Join-Path $script:TLMirror '.git\timeline-checkout-index'
    if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }
    $env:GIT_INDEX_FILE = $idx
    try { return ((Invoke-Git @('checkout', $Commit, '--', "$AppId/")) -eq 0) }
    finally {
        Remove-Item env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        if (Test-Path $idx) { Remove-Item $idx -Force -ErrorAction SilentlyContinue }
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

    if (-not (Expand-AppTree $AppId $tip)) {
        return @{ Ok = $false; Message = 'Could not read that timeline out of git.' }
    }
    $label  = Get-TimelineLabel $AppId $Branch
    $commit = New-AppCommit $AppId $main "[$AppId] ${GameName}: CANONICAL from $label ($($tip.Substring(0,8)))"
    Set-ActiveTimeline $AppId $main
    return @{ Ok = $true; Commit = $commit; Branch = $main; From = $label }
}

function Get-LastSnapshotTime([string]$AppId, [string]$Branch) {
    if (-not (Test-Timeline $Branch)) { return $null }
    $d = Get-GitLine @('log', '-1', '--format=%aI', $Branch)
    if ($d) { try { return [datetime]$d } catch {} }
    return $null
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

    foreach ($ref in @(Get-GitOutput @('for-each-ref', '--format=%(refname:short)', 'refs/heads/game/'))) {
        $ref = ([string]$ref).Trim()
        if (-not $ref) { continue }
        $parts = $ref -split '/'
        if ($parts.Count -ne 3 -or $parts[1] -notmatch '^\d+$') { continue }   # already named

        $appId = $parts[1]
        $new   = "game/$(Get-GameSlug $appId)-$appId/$($parts[2])"
        if ($new -eq $ref) { continue }
        if ((Invoke-Git @('branch', '-m', $ref, $new)) -ne 0) { continue }

        $renamed++
        foreach ($k in @($map.Keys)) {
            if ($map[$k] -eq $ref) { $map[$k] = $new; $mapChanged = $true }
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
