<#
steam_save_roots.ps1: resolve Steam Cloud "root" codes to real paths.

Steam's per-app sync ledger (userdata\<uid>\<appid>\remotecache.vdf) lists every
cloud file with a numeric "root". Root 0 means the game's own remote\ folder;
any other value means the save actually lives elsewhere on disk. AppData,
Documents, the game's install directory. Those are the files the watcher used to
warn about and skip, and they include the owner's lost-save game.

Dot-source it for the functions:  . "$PSScriptRoot\steam_save_roots.ps1"
Run it as a diagnostic:           powershell -ExecutionPolicy Bypass -File steam_save_roots.ps1 -Report

The root table below was verified on this machine: take a real entry out of a
remotecache.vdf, resolve it through the table, confirm the file is on disk.
-Report re-runs exactly that check for every game with cloud files. Codes
outside the table are probed against the usual save locations at runtime, so an
unknown root degrades to "found it anyway, here's where" instead of "skipped".
#>
param([switch]$Report)

$ErrorActionPreference = 'Stop'

# ---------------- VDF / ACF parsing ----------------

function ConvertFrom-Vdf([string]$Text) {
    # Valve KeyValues: "key" "value" pairs and "key" { ... } blocks, nothing else.
    # Returns nested ordered hashtables (key lookup is case-insensitive).
    $rx      = [regex]'"((?:\\.|[^"\\])*)"|\{|\}'
    $root    = [ordered]@{}
    $stack   = New-Object System.Collections.Stack
    $current = $root
    $key     = $null

    foreach ($m in $rx.Matches($Text)) {
        if ($m.Value -eq '{') {
            $child = [ordered]@{}
            if ($null -ne $key) { $current[$key] = $child; $key = $null }
            $stack.Push($current)
            $current = $child
        }
        elseif ($m.Value -eq '}') {
            if ($stack.Count -gt 0) { $current = $stack.Pop() }
        }
        else {
            $s = $m.Groups[1].Value
            if ($s.IndexOf('\') -ge 0) { $s = $s -replace '\\\\', '\' -replace '\\"', '"' }
            if ($null -eq $key) { $key = $s } else { $current[$key] = $s; $key = $null }
        }
    }
    return $root
}

# ---------------- Steam layout ----------------

function Get-NormalPath([string]$Path) {
    # The registry hands back 'c:/program files (x86)/steam'; libraryfolders.vdf
    # hands back 'C:\Program Files (x86)\Steam'. Same folder, and they have to
    # compare equal or every library gets visited twice.
    if (-not $Path) { return $null }
    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath.TrimEnd('\') } catch {}
    return $Path.Replace('/', '\').TrimEnd('\')
}

function Find-SteamRoot {
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath).SteamPath
        if ($p -and (Test-Path (Join-Path $p 'userdata'))) { return (Get-NormalPath $p) }
    } catch {}
    foreach ($p in @('C:\Program Files (x86)\Steam', 'C:\Program Files\Steam')) {
        if (Test-Path (Join-Path $p 'userdata')) { return (Get-NormalPath $p) }
    }
    throw 'Could not find Steam; edit Find-SteamRoot.'
}

function Get-SteamLibraries([string]$SteamRoot) {
    # Games live across several drives; root 1 (and game names) need all of them.
    $libs = @(Get-NormalPath $SteamRoot)
    $f = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path $f) {
        $v  = ConvertFrom-Vdf (Get-Content $f -Raw -Encoding UTF8)
        $lf = $v['libraryfolders']
        if ($lf) {
            foreach ($k in @($lf.Keys)) {
                $e = $lf[$k]
                if (($e -is [System.Collections.IDictionary]) -and $e['path']) {
                    $libs += (Get-NormalPath ([string]$e['path']))
                }
            }
        }
    }
    # Select-Object -Unique is case-SENSITIVE in PS 5.1, and these paths differ
    # only in case, so dedupe explicitly.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    return @($libs | Where-Object { $_ -and (Test-Path $_) -and $seen.Add($_) })
}

function Get-AppInstallDir([string]$AppId, [string]$SteamRoot) {
    foreach ($lib in (Get-SteamLibraries $SteamRoot)) {
        $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path $acf)) { continue }
        $state = (ConvertFrom-Vdf (Get-Content $acf -Raw -Encoding UTF8))['AppState']
        if ($state -and $state['installdir']) {
            return (Join-Path $lib ('steamapps\common\' + $state['installdir']))
        }
    }
    return $null   # game not installed on this PC
}

function Get-GameNames([string]$SteamRoot) {
    $names = @{}
    foreach ($lib in (Get-SteamLibraries $SteamRoot)) {
        Get-ChildItem (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue |
        ForEach-Object {
            # -Encoding UTF8: Valve writes UTF-8, and the default ANSI read
            # turns every ™ / é in a game name into mojibake in games.json.
            $state = (ConvertFrom-Vdf (Get-Content $_.FullName -Raw -Encoding UTF8))['AppState']
            if ($state -and $state['appid'] -and $state['name']) {
                $names[[string]$state['appid']] = [string]$state['name']
            }
        }
    }
    return $names
}

# ---------------- root codes ----------------

function Get-KnownFolderPath([string]$Guid, [string]$Fallback) {
    foreach ($hive in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
                        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders')) {
        try {
            $p = (Get-ItemProperty $hive -Name $Guid -ErrorAction Stop).$Guid
            if ($p) { return [Environment]::ExpandEnvironmentVariables($p) }
        } catch {}
    }
    return $Fallback
}

function Get-LocalLowPath {
    return (Get-KnownFolderPath '{A520A1A4-1780-4FF6-BD18-167343C5AF16}' (Join-Path $env:USERPROFILE 'AppData\LocalLow'))
}

function Get-SavedGamesPath {
    return (Get-KnownFolderPath '{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}' (Join-Path $env:USERPROFILE 'Saved Games'))
}

# code -> short name, which is also the mirror folder name. These names are an
# on-disk contract: renaming one orphans everything already committed under it.
$script:SteamRootNames = @{
    0  = 'remote'        # userdata\<uid>\<appid>\remote
    1  = 'gameinstall'   # steamapps\common\<installdir>
    2  = 'documents'     # Documents (honours OneDrive / redirected Documents)
    3  = 'localappdata'  # %LOCALAPPDATA%
    4  = 'appdata'       # %APPDATA%
    12 = 'locallow'      # %USERPROFILE%\AppData\LocalLow
}

function Get-SteamRootName([int]$Code) {
    if ($script:SteamRootNames.ContainsKey($Code)) { return $script:SteamRootNames[$Code] }
    return $null
}

function Resolve-SteamRootBase {
    <#
    Absolute base directory for a root, given either the numeric code or the
    short name. $AppDir is the userdata\<uid>\<appid> folder (root 0 needs it).
    Returns $null when the root is unknown or its base cannot be located.
    #>
    param(
        [Parameter(Mandatory = $true)] $Root,
        [string]$AppId,
        [string]$SteamRoot,
        [string]$AppDir
    )
    if ($Root -is [string] -and $Root -notmatch '^\d+$') { $name = $Root }
    else { $name = Get-SteamRootName ([int]$Root) }

    switch ($name) {
        'remote'       { if ($AppDir) { return (Join-Path $AppDir 'remote') } return $null }
        'gameinstall'  { return (Get-AppInstallDir $AppId $SteamRoot) }
        'documents'    { return [Environment]::GetFolderPath('MyDocuments') }
        'localappdata' { return $env:LOCALAPPDATA }
        'appdata'      { return $env:APPDATA }
        'locallow'     { return (Get-LocalLowPath) }
        'savedgames'   { return (Get-SavedGamesPath) }
        'userprofile'  { return $env:USERPROFILE }
        'publicdocs'   { return (Join-Path $env:PUBLIC 'Documents') }
    }
    return $null
}

function Find-SteamRootBaseByProbe {
    <#
    Fallback for a root code that is not in the table: try the usual save
    locations and keep the one where the file actually is. Returns
    @{ Base = <path>; Name = <short name> } or $null.
    #>
    param([string]$RelPath, [string]$AppId, [string]$SteamRoot, [string]$AppDir)

    $remote = $null
    if ($AppDir) { $remote = Join-Path $AppDir 'remote' }

    $candidates = [ordered]@{
        'localappdata' = $env:LOCALAPPDATA
        'appdata'      = $env:APPDATA
        'documents'    = [Environment]::GetFolderPath('MyDocuments')
        'locallow'     = (Get-LocalLowPath)
        'savedgames'   = (Get-SavedGamesPath)
        'userprofile'  = $env:USERPROFILE
        'publicdocs'   = (Join-Path $env:PUBLIC 'Documents')
        'gameinstall'  = (Get-AppInstallDir $AppId $SteamRoot)
        'remote'       = $remote
    }
    foreach ($k in @($candidates.Keys)) {
        $base = $candidates[$k]
        if ($base -and (Test-Path (Join-Path $base $RelPath))) {
            return @{ Base = $base; Name = $k }
        }
    }

    # Last resort for root 1 when the app has no appmanifest_<id>.acf to name its
    # install folder (Steam's own Controller Configs app is one): walk the
    # install folders and keep the one that actually holds this file.
    foreach ($lib in (Get-SteamLibraries $SteamRoot)) {
        $common = Join-Path $lib 'steamapps\common'
        if (-not (Test-Path $common)) { continue }
        foreach ($d in (Get-ChildItem $common -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path (Join-Path $d.FullName $RelPath)) {
                return @{ Base = $d.FullName; Name = 'gameinstall' }
            }
        }
    }
    return $null
}

# ---------------- the ledger ----------------

function Read-RemoteCache([string]$CachePath) {
    <#
    Entries of a remotecache.vdf / remotecache.vcf, one object per cloud file.
    RelPath is the path Steam stores, relative to that entry's own root.
    #>
    $doc = ConvertFrom-Vdf (Get-Content $CachePath -Raw -Encoding UTF8)
    $app = $null
    foreach ($k in @($doc.Keys)) {
        if ($doc[$k] -is [System.Collections.IDictionary]) { $app = $doc[$k]; break }
    }
    if (-not $app) { return @() }

    $out = @()
    foreach ($k in @($app.Keys)) {
        $e = $app[$k]
        if (-not ($e -is [System.Collections.IDictionary])) { continue }   # ChangeNumber, OSType
        $out += [pscustomobject]@{
            RelPath = ($k -replace '/', '\')
            Root    = [int]$e['root']
            Size    = [int64]$e['size']
            Sha     = [string]$e['sha']
            Sync    = [string]$e['syncstate']
        }
    }
    return $out
}

function Get-SaveFileMap {
    <#
    Every cloud file of one app: where it lives now, and where it belongs in the
    mirror. Root 0 entries are included for completeness, but the watcher mirrors
    remote\ wholesale, that also catches files Steam has not indexed yet.

      Source    absolute path on disk
      MirrorRel path under <mirror>\<appid>\  (remote\... or roots\<name>\...)
      Missing   listed by Steam, not present on disk
      Unmapped  root code that could not be resolved at all, nothing mirrored
    #>
    param([string]$CachePath, [string]$SteamRoot)

    $appDir = Split-Path $CachePath -Parent
    $appId  = Split-Path $appDir -Leaf
    $out    = @()

    foreach ($e in (Read-RemoteCache $CachePath)) {
        $name   = Get-SteamRootName $e.Root
        $base   = Resolve-SteamRootBase -Root $e.Root -AppId $appId -SteamRoot $SteamRoot -AppDir $appDir
        $probed = $false
        if (-not $base) {
            $hit = Find-SteamRootBaseByProbe -RelPath $e.RelPath -AppId $appId -SteamRoot $SteamRoot -AppDir $appDir
            if ($hit) { $base = $hit.Base; $name = $hit.Name; $probed = $true }
        }

        $src = $null
        if ($base) { $src = Join-Path $base $e.RelPath }

        $mirrorRel = $null
        if ($name -eq 'remote')  { $mirrorRel = Join-Path 'remote' $e.RelPath }
        elseif ($name)           { $mirrorRel = Join-Path (Join-Path 'roots' $name) $e.RelPath }

        $out += [pscustomobject]@{
            AppId     = $appId
            RootCode  = $e.Root
            RootName  = $name
            Base      = $base
            RelPath   = $e.RelPath
            Source    = $src
            MirrorRel = $mirrorRel
            Probed    = $probed
            Unmapped  = (-not $base)
            Missing   = ([bool]$base -and -not (Test-Path $src))
            Size      = $e.Size
            Sha       = $e.Sha
        }
    }
    return $out
}

function Get-RemoteCachePaths([string]$SteamRoot) {
    # Steam names it remotecache.vdf; older clients wrote remotecache.vcf.
    return @(Get-ChildItem (Join-Path $SteamRoot 'userdata') -Recurse -File `
                -Include 'remotecache.vdf', 'remotecache.vcf' -ErrorAction SilentlyContinue)
}

# ---------------- diagnostic ----------------

function Show-RootReport {
    $steamRoot = Find-SteamRoot
    $names     = Get-GameNames $steamRoot
    Write-Host "steam    $steamRoot"
    foreach ($l in (Get-SteamLibraries $steamRoot)) { Write-Host "library  $l" }
    Write-Host ''

    $unmapped = [ordered]@{}
    foreach ($cache in (Get-RemoteCachePaths $steamRoot)) {
        $appId = Split-Path (Split-Path $cache.FullName -Parent) -Leaf
        $map   = @(Get-SaveFileMap -CachePath $cache.FullName -SteamRoot $steamRoot)
        if ($map.Count -eq 0) { continue }

        $label = 'app ' + $appId
        if ($names.ContainsKey($appId)) { $label = $names[$appId] }
        Write-Host ("{0,-9} {1}" -f $appId, $label)

        foreach ($g in ($map | Group-Object RootCode | Sort-Object { [int]$_.Name })) {
            $s    = $g.Group[0]
            $miss = @($g.Group | Where-Object { $_.Missing }).Count
            if ($s.Unmapped) {
                $unmapped[[string]$s.RootCode] = $s.RelPath
                Write-Host ("    root {0,-3} UNMAPPED  {1} file(s) - e.g. {2}" -f $s.RootCode, $g.Count, $s.RelPath) -ForegroundColor Red
                continue
            }
            $tag = $s.RootName
            if ($s.Probed) { $tag = $s.RootName + ' (probed)' }
            $col = 'Green'
            if ($miss -eq $g.Count) { $col = 'DarkGray' } elseif ($miss -gt 0) { $col = 'Yellow' }
            Write-Host ("    root {0,-3} {1,-20} {2} file(s), {3} on disk" -f $s.RootCode, $tag, $g.Count, ($g.Count - $miss)) -ForegroundColor $col
            Write-Host ("              {0}" -f $s.Base) -ForegroundColor $col
        }
    }

    if ($unmapped.Count -gt 0) {
        Write-Host ''
        Write-Host 'Unmapped root codes. Find one of the example files on disk, then add the' -ForegroundColor Red
        Write-Host 'code to $script:SteamRootNames and a case to Resolve-SteamRootBase:'      -ForegroundColor Red
        foreach ($k in @($unmapped.Keys)) { Write-Host ("    root {0}  e.g. {1}" -f $k, $unmapped[$k]) }
    }
}

if ($Report) { Show-RootReport }
