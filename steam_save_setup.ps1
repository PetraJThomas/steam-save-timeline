<#
steam_save_setup.ps1: first-run setup for the Steam save timeline.

Checks the prerequisites, says plainly what it found in your Steam library,
then builds the mirror and takes the first snapshot of every game. It can also
arrange for capture to start when you log in, put the Steam Save Timeline Browser on your
desktop, and attach a private remote so the history survives the drive.

Safe to re-run: everything it does is idempotent. On an existing install it
reports the current state and can repair the pieces that are missing.

Run:  powershell -ExecutionPolicy Bypass -File steam_save_setup.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms      # FolderBrowserDialog

. (Join-Path $PSScriptRoot 'steam_save_settings.ps1')
. (Join-Path $PSScriptRoot 'steam_save_theme.ps1')
. (Join-Path $PSScriptRoot 'steam_save_capture.ps1')   # brings roots + timelines with it
$cfg       = Get-SteamSaveSettings
$MirrorDir = $cfg.MirrorDir
$TaskName  = $cfg.TaskName
Initialize-Capture $MirrorDir

$script:SteamRoot = $null
$script:Ready     = $false
$script:Done      = $false
$script:Findings  = @{}

# ---------------- checks ----------------

function Test-GitPresent {
    try {
        $v = (& git --version 2>$null | Select-Object -First 1)
        if ($v) { return @{ Ok = $true; Detail = $v } }
    } catch {}
    return @{ Ok = $false; Detail = 'not on PATH' }
}

function Test-GitIdentity {
    $n = (& git config --global user.name  2>$null | Select-Object -First 1)
    $e = (& git config --global user.email 2>$null | Select-Object -First 1)
    if ($n -and $e) { return @{ Ok = $true; Warn = $false; Detail = "$n <$e>" } }
    # Not fatal: git only needs an identity to write a commit, and the mirror
    # can carry its own. Say so rather than failing the whole setup.
    return @{ Ok = $true; Warn = $true; Detail = 'not set globally, so the mirror will be given its own' }
}

function Test-SteamPresent {
    try {
        $r = Find-SteamRoot
        $profiles = @(Get-ChildItem (Join-Path $r 'userdata') -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^\d+$' })
        if ($profiles.Count -eq 0) {
            return @{ Ok = $false; Detail = "found at $r, but no user profile in userdata. Sign in to Steam once, then re-run" }
        }
        $script:SteamRoot = $r
        return @{ Ok = $true; Detail = $r }
    } catch {
        return @{ Ok = $false; Detail = 'not found, install or sign in to Steam, then re-run' }
    }
}

function Get-LibrarySurvey {
    <# What is actually there to protect, and how much of it lives outside Steam. #>
    $caches   = @(Get-RemoteCachePaths $script:SteamRoot)
    $external = 0
    $unmapped = @()
    foreach ($c in $caches) {
        $map = @(Get-SaveFileMap -CachePath $c.FullName -SteamRoot $script:SteamRoot)
        if ($map | Where-Object { $_.RootCode -ne 0 -and -not $_.Unmapped }) { $external++ }
        foreach ($u in ($map | Where-Object { $_.Unmapped })) { $unmapped += $u.RootCode }
    }
    return @{
        Games    = $caches.Count
        External = $external
        Unmapped = @($unmapped | Select-Object -Unique)
    }
}

function Test-ExistingInstall {
    $hasRepo = Test-Path (Join-Path $MirrorDir '.git')
    $task    = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Steam Save Timeline.lnk'
    return @{
        Repo    = $hasRepo
        Task    = [bool]$task
        Startup = (Test-Path $startup)
        Games   = $(if ($hasRepo) { @(Get-GitOutput @('branch', '--list', 'game/*/main')).Count } else { 0 })
    }
}



function Test-OneDriveFolder([string]$Path) {
    foreach ($v in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($v -and $Path -and $Path.TrimEnd('\').StartsWith($v.TrimEnd('\'), 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

function Get-SecondCopyStatus {
    <#
    Whether the second copy is actually current. Snapshots push as they happen,
    so an unplugged drive or a paused sync means it quietly stops keeping up.
    That belongs on screen, not in a console nobody reads.
    #>
    $url = Get-GitLine @('remote', 'get-url', 'origin')
    if (-not $url) { return $null }

    $heads = @(Get-GitOutput @('ls-remote', '--heads', 'origin'))
    if ($LASTEXITCODE -ne 0) { return @{ Url = $url; Reachable = $false } }

    $remote = @{}
    foreach ($l in $heads) {
        $hash, $ref = ([string]$l) -split '\s+', 2
        if ($ref) { $remote[$ref.Trim()] = $hash }
    }
    $behind = 0; $total = 0
    foreach ($l in (Get-GitOutput @('for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads/'))) {
        $hash, $ref = ([string]$l) -split '\s+', 2
        if (-not $ref) { continue }
        $total++
        if ($remote[$ref.Trim()] -ne $hash) { $behind++ }
    }
    return @{ Url = $url; Reachable = $true; Total = $total; Behind = $behind }
}

# ---------------- actions ----------------

function Test-Winget {
    try { return [bool](Get-Command winget -ErrorAction SilentlyContinue) } catch { return $false }
}

function Update-PathFromMachine {
    # A freshly installed tool is on the *machine* PATH, not this process's copy.
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-Dependency {
    <#
    Install a missing dependency through winget, with explicit consent every
    time. Installing software is a real change to someone's machine and is not
    trivially undoable, so it is never done silently or as a side effect of
    pressing "Set up". It takes its own button and its own yes.
    #>
    param([string]$WingetId, [string]$Name, [string]$Manual)

    if (-not (Test-Winget)) {
        [System.Windows.MessageBox]::Show(
            "$Name is missing, and winget (Windows Package Manager) is not available to install it.`n`nInstall it manually from:`n$Manual`n`nThen re-run this setup.",
            'Install needed', 'OK', 'Information') | Out-Null
        return $false
    }

    $ok = [System.Windows.MessageBox]::Show(
        "Install $Name now?`n`nThis runs:`n    winget install --id $WingetId`n`nIt downloads and installs from the Windows Package Manager, and may show a UAC prompt.",
        "Install $Name", 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return $false }

    $ProgressPanel.Visibility = 'Visible'
    Write-Log "[install] $Name via winget..."
    $out = Join-Path $env:TEMP "sst-winget-$([guid]::NewGuid().ToString('N')).log"
    try {
        $p = Start-Process winget -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out `
             -ArgumentList @('install', '--id', $WingetId, '-e', '--source', 'winget',
                             '--accept-source-agreements', '--accept-package-agreements')
        foreach ($line in (Get-Content $out -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })) {
            Write-Log "  $line"
        }
        if ($p.ExitCode -ne 0) { Write-Log "[install] winget exited $($p.ExitCode)"; return $false }
    } catch {
        Write-Log "[install] failed: $_"
        return $false
    } finally {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
    Update-PathFromMachine
    Write-Log "[install] $Name installed"
    return $true
}

function Find-Ahk2Exe {
    foreach ($base in @("$env:ProgramFiles\AutoHotkey", "${env:ProgramFiles(x86)}\AutoHotkey")) {
        $c = Join-Path $base 'Compiler\Ahk2Exe.exe'
        $v = Join-Path $base 'v2\AutoHotkey64.exe'
        if ((Test-Path $c) -and (Test-Path $v)) { return @{ Compiler = $c; Base = $v } }
    }
    return $null
}

function Build-TrayApp {
    <# Compile SteamSaveTimeline.ahk, installing AutoHotkey first if consented. #>
    $src = Join-Path $PSScriptRoot 'SteamSaveTimeline.ahk'
    $out = Join-Path $PSScriptRoot 'SteamSaveTimeline.exe'
    if (-not (Test-Path $src)) { Write-Log '[build] SteamSaveTimeline.ahk is not here'; return $false }

    $ahk = Find-Ahk2Exe
    if (-not $ahk) {
        if (-not (Install-Dependency 'AutoHotkey.AutoHotkey' 'AutoHotkey v2' 'https://www.autohotkey.com/')) { return $false }
        $ahk = Find-Ahk2Exe
        if (-not $ahk) { Write-Log '[build] AutoHotkey installed but the compiler was not found'; return $false }
    }

    $ProgressPanel.Visibility = 'Visible'
    Write-Log '[build] compiling the tray app...'
    try {
        $p = Start-Process $ahk.Compiler -Wait -PassThru -WindowStyle Hidden `
             -ArgumentList @('/in', "`"$src`"", '/out', "`"$out`"", '/base', "`"$($ahk.Base)`"")
        if ($p.ExitCode -ne 0 -or -not (Test-Path $out)) {
            Write-Log "[build] Ahk2Exe exited $($p.ExitCode)"
            return $false
        }
    } catch { Write-Log "[build] failed: $_"; return $false }
    Write-Log ("[build] SteamSaveTimeline.exe ({0:N2} MB, bundles the AHK runtime)" -f ((Get-Item $out).Length / 1MB))
    return $true
}

function Move-Mirror([string]$From, [string]$To) {
    <#
    Relocate the timeline itself. This is a save history, so it moves in one
    operation and is checked afterwards: Move-Item handles the cross-volume
    copy-then-delete, and nothing here removes anything of its own accord. It
    refuses rather than merges if the destination already holds something.
    #>
    if ($From -eq $To) { return }
    if (-not (Test-Path (Join-Path $From '.git'))) {
        Write-Log "[move] nothing at $From yet, the timeline will be created at $To"
        return
    }
    if ((Test-Path $To) -and @(Get-ChildItem $To -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        throw "$To already exists and is not empty"
    }

    $before = @(& git -C $From branch --list).Count
    Write-Log "[move] $From -> $To"
    $parent = Split-Path $To -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Move-Item -LiteralPath $From -Destination $To -Force

    $after = @(& git -C $To branch --list).Count
    if (-not (Test-Path (Join-Path $To '.git')) -or $after -ne $before) {
        throw "the move did not verify: $before timelines before, $after after"
    }
    Write-Log "[move] verified, $after timelines intact"
}

function New-FolderShortcut([string]$Path, [string]$Target, [string]$Desc) {
    $sh = New-Object -ComObject WScript.Shell
    $s  = $sh.CreateShortcut($Path)
    $s.TargetPath  = $Target
    $s.Description = $Desc
    $s.Save()
}

function New-Shortcut {
    <#
    $IconLocation matters for anything launched through wscript or powershell.
    Without it the shortcut shows the HOST program's icon, which is why the
    desktop shortcut looked like a script file rather than this app.
    #>
    param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir,
          [string]$Desc, [string]$IconLocation)

    $sh = New-Object -ComObject WScript.Shell
    $s  = $sh.CreateShortcut($Path)
    $s.TargetPath       = $Target
    $s.Arguments        = $Arguments
    $s.WorkingDirectory = $WorkDir
    $s.Description      = $Desc
    if ($IconLocation) { $s.IconLocation = $IconLocation }
    $s.Save()
}

function Register-AtLogon([string]$Method) {
    <#
    Two ways to start capture at log on. The tray app is nicer to live with, it gives you a way back to the browser and a clean way to stop capture, but it is only there if the exe has been built. Task Scheduler needs no
    exe and survives someone deleting the shortcut.
    #>
    $exe = Join-Path $PSScriptRoot 'SteamSaveTimeline.exe'
    if ($Method -eq 'exe' -and (Test-Path $exe)) {
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Steam Save Timeline.lnk'
        New-Shortcut $lnk $exe '' $PSScriptRoot 'Capture Steam Cloud saves into a git timeline'
        return "startup shortcut -> $exe"
    }

    # Through the shim, so logging in does not flash a console at you.
    $shim    = Join-Path $PSScriptRoot 'run-hidden.vbs'
    $action  = New-ScheduledTaskAction -Execute 'wscript.exe' `
                 -Argument "`"$shim`" steam_save_watcher.ps1" `
                 -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    # No execution time limit: this is a daemon, not a job that finishes.
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $set `
        -Description 'Mirrors Steam Cloud saves into a git timeline so a bad sync can be rolled back.' `
        -Force | Out-Null
    return "scheduled task '$TaskName' (at log on)"
}

# --- the second copy -------------------------------------------------------
# Nobody setting this up wants to learn git. They want their saves to exist
# somewhere other than this drive. So these are phrased and shaped as
# destinations, and the git underneath never surfaces outside the log.

function Connect-FolderCopy([string]$Folder) {
    <# An external drive, a synced folder, a NAS share. No account, no concepts. #>
    if (-not (Test-Path $Folder)) {
        # Create it. Refusing was absurd: Choose... appends a subfolder name to
        # whatever was picked, so the tool invented a path and then complained
        # the path did not exist. A drive that is not there is a real problem
        # though, and says so rather than being silently invented.
        $root = [IO.Path]::GetPathRoot($Folder)
        if ($root -and -not (Test-Path $root)) {
            throw "that drive is not available: $root"
        }
        try { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
        catch { throw "could not create $Folder ($($_.Exception.Message))" }
        Write-Log "[copy] created $Folder"
    }
    $target = Join-Path $Folder 'steam-save-history.git'
    if (-not (Test-Path $target)) {
        & git init --bare --quiet -- $target 2>&1 | Out-Null
        if (-not (Test-Path $target)) { throw "couldn't create the copy at $target" }
        Write-Log "[copy] created $target"
    }
    Write-CopyInstructions $Folder
    return $target
}

function Write-CopyInstructions([string]$Folder) {
    <#
    A backup you cannot see is a backup you do not trust.

    The copy is a bare repository, which is the right shape (full history, no
    conflict copies of individual saves, a few packed files instead of
    thousands) but it means opening the folder shows git internals and none of
    your saves. So the folder explains itself, and ships a script that turns it
    back into ordinary browsable folders without anyone needing to know git.
    #>
    $readme = @"
YOUR STEAM SAVES ARE IN HERE
============================

"Your saves (latest)"
    Your save files, as ordinary folders, one per game. Nothing special is
    needed to use these: open the folder and copy what you want. This is the
    most recent capture of each game.

"steam-save-history.git"
    The full history: every game, and every point in time ever captured, not
    just the latest. It does not look like save files because it is stored as
    a repository, which is what lets it hold the whole history in a few small
    files instead of thousands, and give every file back byte for byte.

So: if you just need your saves, use the first folder. If you need an OLDER
save (the one from before something went wrong), use the history.

NEW PC? PUT EVERYTHING BACK
---------------------------
1. Download the Steam Save Timeline release zip.
2. Extract it INTO THIS FOLDER, next to the files already here.
3. Double-click  "Restore my saves.exe"

It finds this backup sitting beside it, tells you what it found, and restores
every game with its whole history. Nothing needs moving out of OneDrive or
Google Drive first, and there are no paths to type.

Capturing resumes from there, and keeps copying back to this same folder.

(Already running it? Right-click the tray icon and choose Setup instead. Same
window, same result.)

GETTING ONE OLDER SAVE BACK
---------------------------
If you only want a single earlier save and do not want to install anything,
double-click:  recover-my-saves.cmd

It writes a "recovered-saves" folder here with every game's history unpacked.
Nothing already here is changed or deleted.

That step needs Git for Windows (https://git-scm.com/download/win). If you do
not have it and do not want it, the "Your saves (latest)" folder still works
on its own, with no tools at all.

Written by Steam Save Timeline:
https://github.com/PetraJThomas/steam-save-timeline
"@
    Set-Content (Join-Path $Folder 'READ ME - how to get my saves back.txt') $readme -Encoding UTF8

    $ps1 = @'
# Turns the repository next to this script back into ordinary folders.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Join-Path $here 'steam-save-history.git'
$out  = Join-Path $here 'recovered-saves'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Git is needed. Install it from https://git-scm.com/download/win' -ForegroundColor Red
    return
}
if (-not (Test-Path $repo)) { Write-Host "No repository found at $repo" -ForegroundColor Red; return }

$work = Join-Path $env:TEMP ("sst-recover-" + [guid]::NewGuid().ToString('N'))
Write-Host "Reading $repo ..."
& git clone --quiet $repo $work
if (-not (Test-Path $work)) { Write-Host 'Could not read the repository.' -ForegroundColor Red; return }

New-Item -ItemType Directory -Path $out -Force | Out-Null
$branches = @(& git -C $work branch -r --format='%(refname:short)') |
            Where-Object { $_ -like 'origin/game/*/main' }

foreach ($b in $branches) {
    $local = $b -replace '^origin/', ''
    $name  = ($local -split '/')[1]            # <slug>-<appid>
    & git -C $work checkout --quiet -B recover $b 2>&1 | Out-Null
    $appId = ($name -split '-')[-1]
    $src   = Join-Path $work $appId
    if (Test-Path $src) {
        $dest = Join-Path $out $name
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item $src $dest -Recurse -Force
        $n = @(Get-ChildItem $dest -Recurse -File).Count
        Write-Host ("  {0,-45} {1} file(s)" -f $name, $n)
    }
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Done. Your saves are in: $out" -ForegroundColor Green
Write-Host 'Nothing in the backup was changed.'
'@
    Set-Content (Join-Path $Folder 'recover-my-saves.ps1') $ps1 -Encoding UTF8

    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0recover-my-saves.ps1`"`r`npause`r`n"
    Set-Content (Join-Path $Folder 'recover-my-saves.cmd') $cmd -Encoding ASCII
}

function Connect-GitHubRepo {
    <#
    For someone who has never touched git or GitHub: install the CLI if needed,
    sign in through the browser, make the repo for them. Always --private,
    never offered otherwise, these are personal save files.
    Returns the clone URL, or $null if they backed out.
    #>
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        if (-not (Install-Dependency 'GitHub.cli' 'GitHub CLI' 'https://cli.github.com/')) { return $null }
    }

    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log '[copy] signing in to GitHub...'
        Start-Process powershell -ArgumentList '-NoProfile', '-Command',
            'gh auth login --hostname github.com --git-protocol https --web; Write-Host ""; Read-Host "Done - press Enter to close"'
        [System.Windows.MessageBox]::Show(
            "Setting up your free online backup.`n`nA window has opened and will send you to your browser to sign in to GitHub. Most people only know GitHub as somewhere they download things from, it also gives you a free private space to keep files, and that is all it is being used for here. If you don't have an account, you can create one on that page.`n`nFinish in the browser, then come back and press OK.",
            'One-time sign-in', 'OK', 'Information') | Out-Null
        & gh auth status 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log '[copy] not signed in, skipped'; return $null }
    }
    & gh auth setup-git 2>&1 | Out-Null          # lets git push without asking for a password

    $owner = (& gh api user --jq .login 2>$null | Select-Object -First 1)
    if (-not $owner) { Write-Log '[copy] could not read your GitHub account'; return $null }

    $name = 'steam-save-history'
    & gh repo view "$owner/$name" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "[copy] using your existing private repo $owner/$name"
    } else {
        & gh repo create $name --private --description 'Version history for my Steam Cloud saves' 2>&1 |
            ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) { Write-Log '[copy] could not create the repo'; return $null }
        Write-Log "[copy] created private repo $owner/$name"
    }
    return "https://github.com/$owner/$name.git"
}

function Save-SecondCopy([string]$Url) {
    if ((Invoke-Git @('remote', 'get-url', 'origin')) -eq 0) {
        Invoke-Git @('remote', 'set-url', 'origin', $Url) | Out-Null
    } else {
        Invoke-Git @('remote', 'add', 'origin', $Url) | Out-Null
    }
    # --all so every game's timeline goes, not just whatever HEAD points at.
    if ((Invoke-Git @('push', '--all', 'origin')) -ne 0) {
        return "destination saved, but the first copy failed, check $Url"
    }

    # And the plain, no-tools-required copy of the current saves beside it.
    $plain = 0
    foreach ($g in (Get-ChildItem $MirrorDir -Directory | Where-Object { $_.Name -match '^\d+$' })) {
        Update-PlainCopy $g.Name $g.FullName
        $plain++
    }
    if ($plain -gt 0) { Write-Log "[copy] wrote $plain game(s) as plain files too" }

    return "every timeline copied to $Url"
}

# ---------------- UI ----------------

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam Save Timeline - Setup" Width="800" Height="720" MinWidth="700" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#0F1319"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
$SteamSaveTheme
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
            BorderThickness="0,0,0,1" Padding="22,16">
      <StackPanel>
        <TextBlock Text="Steam Save Timeline" FontSize="19" FontWeight="SemiBold"/>
        <TextBlock Margin="0,4,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                   Text="Steam Cloud keeps one slot per file and no history. This gives it one, so a bad sync is a rollback instead of a loss."/>
      </StackPanel>
    </Border>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="22,18,22,18">

        <TextBlock Text="CHECKS" FontSize="10" FontWeight="SemiBold" Foreground="{StaticResource Muted}"/>
        <Border Margin="0,8,0,0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                BorderThickness="1" CornerRadius="6" Padding="14,10">
          <StackPanel Name="CheckList"/>
        </Border>

        <TextBlock Text="OPTIONS" FontSize="10" FontWeight="SemiBold" Foreground="{StaticResource Muted}" Margin="0,20,0,0"/>
        <Border Margin="0,8,0,0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                BorderThickness="1" CornerRadius="6" Padding="14,12">
          <StackPanel>
            <TextBlock Text="Where the timeline is kept" FontSize="12.5" Foreground="{StaticResource Text}"/>
            <DockPanel Margin="24,6,0,0">
              <Button Name="MirrorBrowseBtn" Content="Choose..." Style="{StaticResource Btn}" DockPanel.Dock="Right" Margin="6,0,0,0"/>
              <TextBox Name="MirrorPath"/>
            </DockPanel>
            <TextBlock Name="MirrorNote" Margin="24,6,0,14" FontSize="10.5" TextWrapping="Wrap"
                       Foreground="{StaticResource Muted}"
                       Text="Every save ever captured lives here. Changing it moves what is already there."/>

            <CheckBox Name="OptLogon" IsChecked="True" Content="Start with Windows (keep capturing automatically)"/>
            <StackPanel Name="MethodPanel" Margin="24,6,0,0">
              <RadioButton Name="MethodExe"  GroupName="startup" Content="Tray app (SteamSaveTimeline.exe) - also gives one-click access to the browser"/>
              <RadioButton Name="MethodTask" GroupName="startup" Content="Task Scheduler - no tray icon, nothing to delete by accident" Margin="0,4,0,0"/>
              <Button Name="BuildExeBtn" Content="Build the tray app" Style="{StaticResource Btn}"
                      HorizontalAlignment="Left" Margin="0,8,0,0" Padding="10,4" FontSize="11" Visibility="Collapsed"/>
            </StackPanel>
            <CheckBox Name="OptDesktop" IsChecked="True" Content="Desktop shortcut that opens the Steam Save Timeline Browser" Margin="0,12,0,0"/>
            <CheckBox Name="OptFolderLinks" Content="Desktop shortcuts to the save folders themselves" Margin="0,10,0,0"/>
            <!--
              One radio group that includes "no", rather than a checkbox gating
              a disabled panel. The old shape had two traps: clicking a
              destination while the panel was still disabled was swallowed, and
              the pre-checked default then won silently. Nothing here is
              disabled and nothing is pre-selected except "not right now", so
              the destination used is always the one actually clicked.
            -->
            <TextBlock Text="A second copy, off this drive. A dead drive takes the timeline with it."
                       Margin="0,16,0,0" FontSize="12.5" Foreground="{StaticResource Text}"/>
            <StackPanel Name="RemotePanel" Margin="24,8,0,0">
              <RadioButton Name="CopyNone" GroupName="remote" IsChecked="True" Content="Not right now"/>
              <RadioButton Name="RemoteFolder" GroupName="remote" Margin="0,10,0,0"
                           Content="A folder - external drive, OneDrive, or a network share. No account needed."/>
              <DockPanel Margin="20,5,0,0">
                <Button Name="BrowseBtn" Content="Choose..." Style="{StaticResource Btn}" DockPanel.Dock="Right" Margin="6,0,0,0"/>
                <TextBox Name="FolderPath"/>
              </DockPanel>
              <TextBlock Name="FolderNote" Margin="20,6,0,0" FontSize="10.5" TextWrapping="Wrap"
                         Foreground="{StaticResource Muted}"
                         Text="A repository is created in that folder, not a loose copy of your saves. It keeps the whole history and every file byte for byte."/>
              <RadioButton Name="RemoteGitHub" GroupName="remote" Margin="0,10,0,0"
                           Content="Free online backup - set up for you, start to finish. Nothing to know beforehand."/>
              <TextBlock Margin="20,2,0,0" FontSize="10.5" TextWrapping="Wrap" Foreground="{StaticResource Muted}"
                         Text="Uses GitHub - the site you have probably downloaded things from. It also gives anyone a free private place to keep files, which is what this uses. You will sign in (or sign up) in your browser; everything else is automatic."/>
              <RadioButton Name="RemoteUrlOpt" GroupName="remote" Margin="0,10,0,0"
                           Content="Advanced: I already have a git URL"/>
              <TextBox Name="RemoteUrl" Margin="20,5,0,0" IsEnabled="False"/>
              <TextBlock Margin="0,10,0,0" FontSize="11" TextWrapping="Wrap" Foreground="{StaticResource Good}"
                         Text="Your saves stay private. The online backup is created private - never public, never searchable - and a folder copy inherits that folder's permissions."/>
            </StackPanel>
          </StackPanel>
        </Border>

        <StackPanel Name="ProgressPanel" Visibility="Collapsed">
          <TextBlock Text="PROGRESS" FontSize="10" FontWeight="SemiBold" Foreground="{StaticResource Muted}" Margin="0,20,0,0"/>
          <Border Margin="0,8,0,0" Background="#0B0E13" BorderBrush="{StaticResource Line}"
                  BorderThickness="1" CornerRadius="6" Padding="10">
            <TextBox Name="LogBox" Height="190" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                     FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource Muted}"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
          </Border>
        </StackPanel>

      </StackPanel>
    </ScrollViewer>

    <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
            BorderThickness="0,1,0,0" Padding="22,14">
      <DockPanel LastChildFill="True">
        <Button Name="GoBtn" Content="Set up" Style="{StaticResource BtnPrimary}"
                DockPanel.Dock="Right" Margin="14,0,0,0" IsEnabled="False"/>
        <TextBlock Name="StatusText" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="12"
                   Foreground="{StaticResource Muted}" Text="Checking..."/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

$window        = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$appIcon       = Get-AppIcon; if ($appIcon) { $window.Icon = $appIcon }
$CheckList     = $window.FindName('CheckList')
$OptLogon      = $window.FindName('OptLogon')
$MethodPanel   = $window.FindName('MethodPanel')
$MethodExe     = $window.FindName('MethodExe')
$MethodTask    = $window.FindName('MethodTask')
$OptDesktop    = $window.FindName('OptDesktop')
$CopyNone      = $window.FindName('CopyNone')
$MirrorPath    = $window.FindName('MirrorPath')
$MirrorBrowseBtn = $window.FindName('MirrorBrowseBtn')
$MirrorNote    = $window.FindName('MirrorNote')
$OptFolderLinks = $window.FindName('OptFolderLinks')
$RemotePanel   = $window.FindName('RemotePanel')
$RemoteFolder  = $window.FindName('RemoteFolder')
$RemoteGitHub  = $window.FindName('RemoteGitHub')
$RemoteUrlOpt  = $window.FindName('RemoteUrlOpt')
$FolderPath    = $window.FindName('FolderPath')
$BrowseBtn     = $window.FindName('BrowseBtn')
$FolderNote    = $window.FindName('FolderNote')
$RemoteUrl     = $window.FindName('RemoteUrl')
$BuildExeBtn   = $window.FindName('BuildExeBtn')
$ProgressPanel = $window.FindName('ProgressPanel')
$LogBox        = $window.FindName('LogBox')
$GoBtn         = $window.FindName('GoBtn')
$StatusText    = $window.FindName('StatusText')

function Sync-Ui {
    # Work happens on the UI thread, so pump the dispatcher between steps or
    # the window greys out and looks hung.
    $window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Write-Log([string]$Message) {
    $LogBox.AppendText("$Message`r`n")
    $LogBox.ScrollToEnd()
    Sync-Ui
}

function Add-Check([string]$State, [string]$Label, [string]$Detail, [string]$ActionLabel, [scriptblock]$Action) {
    # System icon font, so these match the rest of the app rather than being
    # whatever the text font happens to draw for a dingbat.
    $glyph, $colour = switch ($State) {
        'ok'   { [char]0xE73E, '#7BD88F' }   # accept
        'warn' { [char]0xE7BA, '#F2C14E' }   # warning
        'fail' { [char]0xE711, '#E06C6C' }   # cancel
        default { [char]0xE946, '#66C0F4' }  # info
    }
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,3'
    foreach ($w in @('Auto', 'Auto', '*', 'Auto')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(0, 'Auto')
        if ($w -eq '*') { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        $row.ColumnDefinitions.Add($cd)
    }
    $g = New-Object System.Windows.Controls.TextBlock
    $g.Text = [string]$glyph
    $g.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($colour)))
    $g.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $g.FontSize = 14; $g.Width = 22; $g.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($g, 0); [void]$row.Children.Add($g)

    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $Label; $l.FontSize = 12.5; $l.MinWidth = 150; $l.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($l, 1); [void]$row.Children.Add($l)

    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $Detail; $d.FontSize = 11.5; $d.Margin = '12,0,0,0'
    $d.TextTrimming = 'CharacterEllipsis'; $d.VerticalAlignment = 'Center'
    $d.Foreground = $window.FindResource('Muted')
    [System.Windows.Controls.Grid]::SetColumn($d, 2); [void]$row.Children.Add($d)

    # A missing dependency gets a button to fix it, right where the problem is
    # named. Never installs anything without its own confirmation.
    if ($ActionLabel -and $Action) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $ActionLabel
        $b.Style   = $window.FindResource('Btn')
        $b.Margin  = '12,0,0,0'
        $b.Padding = '10,3'
        $b.FontSize = 11
        $b.Add_Click($Action)
        [System.Windows.Controls.Grid]::SetColumn($b, 3); [void]$row.Children.Add($b)
    }

    [void]$CheckList.Children.Add($row)
}

function Invoke-Checks {
    $CheckList.Children.Clear()
    $blockers = @()

    $git = Test-GitPresent
    if ($git.Ok) {
        Add-Check 'ok' 'Version history engine' $git.Detail
    } else {
        # The one hard dependency. Offer to fetch it rather than ending the
        # conversation with "go install git".
        Add-Check 'fail' 'Version history engine' 'missing - this is the only thing needed' 'Install it' {
            if (Install-Dependency 'Git.Git' 'Git for Windows' 'https://git-scm.com/download/win') { Invoke-Checks }
        }.GetNewClosure()
        $blockers += 'git'
    }

    $id = Test-GitIdentity
    Add-Check $(if ($id.Warn) { 'warn' } else { 'ok' }) 'Commit identity' $id.Detail

    $steam = Test-SteamPresent
    Add-Check $(if ($steam.Ok) { 'ok' } else { 'fail' }) 'Steam' $steam.Detail
    if (-not $steam.Ok) { $blockers += 'Steam' }
    Sync-Ui

    if ($steam.Ok) {
        $StatusText.Text = 'Reading your Steam library...'
        Sync-Ui
        $survey = Get-LibrarySurvey
        $script:Findings = $survey
        Add-Check 'ok' 'Cloud saves found' "$($survey.Games) games"
        if ($survey.External -gt 0) {
            Add-Check 'ok' 'Outside Steam folders' "$($survey.External) games keep saves in AppData, Documents or their install folder, these are mirrored too"
        }
        if ($survey.Unmapped.Count -gt 0) {
            Add-Check 'warn' 'Unrecognised locations' "root code(s) $($survey.Unmapped -join ', '), run steam_save_roots.ps1 -Report to map them"
        }
    }

    # A backup beside us with no timeline here yet means a fresh machine being
    # put back together. That is the headline, so it goes in before the rest.
    # Tested on timelines, not on the folder: the tray app may already have
    # created an empty mirror before anyone opened this window, and a backup
    # beside us still deserves to be offered.
    $script:Backup = $null
    $hasTimelines = (Test-Path (Join-Path $MirrorDir '.git')) -and
                    (@(Get-GitOutput @('branch', '--list', 'game/*/main')).Count -gt 0)
    if (-not $hasTimelines) {
        $script:Backup = Find-AdjacentBackup $PSScriptRoot
        if ($script:Backup) {
            Add-Check 'ok' 'Backup found beside this' `
                "$($script:Backup.Games) games, last updated $($script:Backup.Updated). Set up will restore it."
        }
    }

    $ex = Test-ExistingInstall
    if ($ex.Repo) {
        Add-Check 'ok' 'Already set up' "$($ex.Games) game timelines at $MirrorDir"
        $GoBtn.Content = 'Update setup'
    }
    $copy = Get-SecondCopyStatus
    if ($copy) {
        if (-not $copy.Reachable) {
            Add-Check 'warn' 'Second copy' "unreachable right now: $($copy.Url)"
        } elseif ($copy.Behind -eq 0) {
            Add-Check 'ok' 'Second copy' "up to date, $($copy.Total) timelines at $($copy.Url)"
        } else {
            Add-Check 'warn' 'Second copy' "$($copy.Behind) of $($copy.Total) timelines not copied yet, at $($copy.Url)"
        }
    }

    if ($ex.Task -or $ex.Startup) {
        $how = if ($ex.Startup) { 'startup shortcut' } else { 'scheduled task' }
        Add-Check 'ok' 'Starts with Windows' $how
        $OptLogon.IsChecked = $true
    }

    # Prefer the tray app when it has been built, since it is the nicer thing
    # to live with; fall back to Task Scheduler when it has not.
    $exe = Join-Path $PSScriptRoot 'SteamSaveTimeline.exe'
    if (Test-Path $exe) {
        $MethodExe.IsChecked      = $true
        $BuildExeBtn.Visibility   = 'Collapsed'
    } else {
        $MethodTask.IsChecked   = $true
        $MethodExe.IsEnabled    = $false
        $MethodExe.Content      = 'Tray app (not built yet)'
        $BuildExeBtn.Visibility = 'Visible'
    }

    $script:Ready = ($blockers.Count -eq 0)
    $GoBtn.IsEnabled = $script:Ready
    $StatusText.Text = if ($script:Ready) {
        "Ready. This will mirror $($script:Findings.Games) games and take the first snapshot of each."
    } else {
        "Cannot continue until this is fixed: $($blockers -join ', ')."
    }
}

function Invoke-Setup {
    $GoBtn.IsEnabled = $false
    $ProgressPanel.Visibility = 'Visible'
    $StatusText.Text = 'Setting up...'
    Set-CaptureLogger { param($m) Write-Log $m }

    try {
        # Relocating has to happen before anything opens the old path.
        $wanted = $MirrorPath.Text.Trim()
        if ($wanted -and $wanted -ne $MirrorDir) {
            Move-Mirror $MirrorDir $wanted
            [void](Set-SteamSaveSetting @{ mirrorDir = $wanted })
            $MirrorDir = $wanted
            Initialize-Capture $MirrorDir
            Write-Log "[config] timeline now kept at $MirrorDir"
        }

        # Restore before anything else: Initialize-Repo would otherwise create
        # an empty timeline and the backup beside us would never be picked up.
        if ($script:Backup) {
            Restore-FromBackup $script:Backup.Path $MirrorDir | Out-Null
            Write-Log "[restore] new saves will keep going back to $($script:Backup.Path)"
        }

        Initialize-Repo
        # A repo with no identity cannot commit; give the mirror its own rather
        # than editing the user's global git config behind their back.
        if ((Invoke-Git @('config', 'user.email')) -ne 0) {
            Invoke-Git @('config', 'user.name',  'Steam Save Timeline') | Out-Null
            Invoke-Git @('config', 'user.email', 'steam-save-timeline@localhost') | Out-Null
            Write-Log '[init] gave the mirror its own commit identity'
        }

        $names = Get-GameNames $script:SteamRoot
        Write-GamesJson $names
        Write-GamesIndex $names
        Set-TimelineGameNames $names
        $renamedRefs = Update-BranchNaming $names
        $plainMoved = Update-PlainCopyNames   # the second copy's folders follow the refs
        if ($renamedRefs -gt 0) { Write-Log "[init] renamed $renamedRefs branch(es) to include game names" }
        $seeded = Initialize-GameTimelines $names
        if ($seeded -gt 0) { Write-Log "[init] created $seeded game timeline(s)" }

        Write-Log '[sweep] taking the first snapshot of every game...'
        $count = Invoke-Sweep $names $script:SteamRoot {
            param($i, $total, $label)
            $StatusText.Text = "Snapshotting $i of $total - $label"
            Sync-Ui
        }
        Write-Log "[sweep] $count game(s) captured"

        if ($OptLogon.IsChecked) {
            $method = if ($MethodExe.IsChecked) { 'exe' } else { 'task' }
            try { Write-Log "[logon] $(Register-AtLogon $method)" }
            catch { Write-Log "[warn] could not set up log-on start: $_" }
        }

        if ($OptDesktop.IsChecked) {
            try {
                # Carries the product name AND what it opens. "Timeline Browser"
                # alone says nothing about Steam on a desktop full of icons, and
                # "Steam Save Timeline" alone is the Startup shortcut for the
                # tray app: two identically named shortcuts doing different
                # things is its own small cruelty.
                $desktop = [Environment]::GetFolderPath('Desktop')
                foreach ($old in 'Steam Save Timeline.lnk', 'Timeline Browser.lnk') {
                    $legacy = Join-Path $desktop $old
                    if (Test-Path $legacy) { Remove-Item $legacy -Force -ErrorAction SilentlyContinue }
                }
                $lnk = Join-Path $desktop 'Steam Save Timeline Browser.lnk'
                New-Shortcut $lnk 'wscript.exe' `
                    "`"$(Join-Path $PSScriptRoot 'run-hidden.vbs')`" steam_save_restore_gui.ps1" `
                    $PSScriptRoot 'Browse and restore your Steam Cloud save timeline' `
                    "$(Join-Path $PSScriptRoot 'SteamSaveTimeline.ico'),0"
                Write-Log "[desktop] $lnk"
            } catch { Write-Log "[warn] could not create the desktop shortcut: $_" }
        }

        # A backup tool must never report success for a backup it did not make,
        # so every way this can come up empty is captured and surfaced, not
        # just written into a log.
        $copyProblem = $null
        if (-not $CopyNone.IsChecked) {
            try {
                $url = $null
                if ($RemoteFolder.IsChecked) {
                    if ($FolderPath.Text.Trim()) { $url = Connect-FolderCopy $FolderPath.Text.Trim() }
                    else { $copyProblem = 'no folder was chosen' }
                }
                elseif ($RemoteGitHub.IsChecked) {
                    $url = Connect-GitHubRepo
                    if (-not $url) { $copyProblem = 'the online backup was not completed' }
                }
                elseif ($RemoteUrlOpt.IsChecked) {
                    if ($RemoteUrl.Text.Trim()) { $url = $RemoteUrl.Text.Trim() }
                    else { $copyProblem = 'no git URL was entered' }
                }

                if ($url) {
                    $msg = Save-SecondCopy $url
                    Write-Log "[copy] $msg"
                    if ($msg -notlike 'every timeline copied*') { $copyProblem = $msg }
                }
            } catch {
                $copyProblem = "$_"
                Write-Log "[warn] second copy: $_"
            }
        }

        if ($OptFolderLinks.IsChecked) {
            try {
                $desk = [Environment]::GetFolderPath('Desktop')
                New-FolderShortcut (Join-Path $desk 'Steam Saves (timeline).lnk') $MirrorDir 'Every save ever captured'
                Write-Log "[desktop] folder shortcut to $MirrorDir"
                # Only a folder destination can be opened; an online backup is a URL.
                if ($RemoteFolder.IsChecked -and $FolderPath.Text.Trim()) {
                    $second = $FolderPath.Text.Trim()
                    New-FolderShortcut (Join-Path $desk 'Steam Saves (second copy).lnk') $second 'The off-drive copy'
                    Write-Log "[desktop] folder shortcut to $second"
                }
            } catch { Write-Log "[warn] folder shortcuts: $_" }
        }

        $script:Done = $true
        $GoBtn.Content   = 'Open the Steam Save Timeline Browser'
        $GoBtn.IsEnabled = $true
        $StatusText.Text = if ($copyProblem) {
            "Capture is set up, but the second copy was NOT made: $copyProblem. Everything else is done."
        } else {
            'Done. Capture runs from now on; every sync Steam makes becomes a point you can go back to.'
        }
        Write-Log ''
        Write-Log "Mirror: $MirrorDir"
        Write-Log 'Nothing in Steam was modified, the watcher only reads.'
    } catch {
        $StatusText.Text = "Setup failed: $_"
        Write-Log "[error] $_"
        $GoBtn.IsEnabled = $true
    }
}

$RemoteUrlOpt.Add_Checked({   $RemoteUrl.IsEnabled = $true; $RemoteUrl.Focus() })
$RemoteUrlOpt.Add_Unchecked({ $RemoteUrl.IsEnabled = $false })

$BuildExeBtn.Add_Click({
    if (Build-TrayApp) {
        $MethodExe.IsEnabled    = $true
        $MethodExe.Content      = 'Tray app (SteamSaveTimeline.exe), also gives one-click access to the browser'
        $MethodExe.IsChecked    = $true
        $BuildExeBtn.Visibility = 'Collapsed'
    }
})

$MirrorBrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Where should the timeline be kept?'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    # Picking "D:\Backups" should not scatter 29 numbered folders into it, so
    # give the timeline its own folder unless one was picked directly.
    $chosen = $dlg.SelectedPath
    if ((Split-Path $chosen -Leaf) -ne 'steam-save-history' -and -not (Test-Path (Join-Path $chosen '.git'))) {
        $chosen = Join-Path $chosen 'steam-save-history'
    }
    $MirrorPath.Text = $chosen
    $MirrorNote.Text = if ($chosen -eq $MirrorDir) {
        'Every save ever captured lives here. Changing it moves what is already there.'
    } elseif (Test-Path (Join-Path $MirrorDir '.git')) {
        "On Set up, the existing timeline is MOVED from $MirrorDir to here. Nothing is copied or left behind."
    } else {
        'The timeline will be created here.'
    }
})

$BrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Where should the second copy live?'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $FolderPath.Text = $dlg.SelectedPath
        $RemoteFolder.IsChecked = $true
        # A synced folder is a fine destination, but it is worth saying what
        # actually lands there, and that two PCs writing to one synced copy is
        # the way to break it.
        if (Test-OneDriveFolder $dlg.SelectedPath) {
            $FolderNote.Text = 'OneDrive will sync this as a repository (a few packed files), not as loose save files, so it stays small and keeps full history. Do not point a second PC at this same folder: two machines writing to one synced copy is what corrupts it.'
        } else {
            $FolderNote.Text = "A repository is created at $($dlg.SelectedPath)\steam-save-history.git, not a loose copy of your saves. It keeps the whole history and every file byte for byte."
        }
    }
})
$OptLogon.Add_Checked({    $MethodPanel.IsEnabled = $true })
$OptLogon.Add_Unchecked({  $MethodPanel.IsEnabled = $false })

$GoBtn.Add_Click({
    if (-not $script:Done) {
        if ($RemoteFolder.IsChecked -and -not $FolderPath.Text.Trim()) {
            $StatusText.Text = 'Choose the folder for the second copy first, or pick "Not right now".'
            return
        }
        if ($RemoteUrlOpt.IsChecked -and -not $RemoteUrl.Text.Trim()) {
            $StatusText.Text = 'Enter the git URL, or pick another destination.'
            return
        }
    }
    if ($script:Done) {
        Start-Process wscript -ArgumentList "`"$(Join-Path $PSScriptRoot 'run-hidden.vbs')`"", 'steam_save_restore_gui.ps1'
        $window.Close()
        return
    }
    Invoke-Setup
})

# Run the checks after the window has painted, so it does not appear frozen
# while the Steam library is surveyed.
$MirrorPath.Text = $MirrorDir
$window.Add_ContentRendered({ Invoke-Checks })
[void]$window.ShowDialog()
