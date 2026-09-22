<#
steam_save_setup.ps1: first-run setup for the Steam save timeline.

Checks the prerequisites, says plainly what it found in your Steam library,
then builds the mirror and takes the first snapshot of every game. It can also
arrange for capture to start when you log in, put the timeline browser on your
desktop, and attach a private remote so the history survives the drive.

Safe to re-run: everything it does is idempotent. On an existing install it
reports the current state and can repair the pieces that are missing.

Run:  powershell -ExecutionPolicy Bypass -File steam_save_setup.ps1
#>

# ---------------- config ----------------
$MirrorDir = Join-Path $env:USERPROFILE 'steam-save-history'
$TaskName  = 'Steam Save Timeline'
# ----------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms      # FolderBrowserDialog

. (Join-Path $PSScriptRoot 'steam_save_theme.ps1')
. (Join-Path $PSScriptRoot 'steam_save_capture.ps1')   # brings roots + timelines with it
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

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Desc) {
    $sh = New-Object -ComObject WScript.Shell
    $s  = $sh.CreateShortcut($Path)
    $s.TargetPath       = $Target
    $s.Arguments        = $Arguments
    $s.WorkingDirectory = $WorkDir
    $s.Description      = $Desc
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
    if (-not (Test-Path $Folder)) { throw "that folder doesn't exist: $Folder" }
    $target = Join-Path $Folder 'steam-save-history.git'
    if (-not (Test-Path $target)) {
        & git init --bare --quiet -- $target 2>&1 | Out-Null
        if (-not (Test-Path $target)) { throw "couldn't create the copy at $target" }
        Write-Log "[copy] created $target"
    }
    return $target
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
            <CheckBox Name="OptLogon" IsChecked="True" Content="Start with Windows (keep capturing automatically)"/>
            <StackPanel Name="MethodPanel" Margin="24,6,0,0">
              <RadioButton Name="MethodExe"  GroupName="startup" Content="Tray app (SteamSaveTimeline.exe) - also gives one-click access to the browser"/>
              <RadioButton Name="MethodTask" GroupName="startup" Content="Task Scheduler - no tray icon, nothing to delete by accident" Margin="0,4,0,0"/>
              <Button Name="BuildExeBtn" Content="Build the tray app" Style="{StaticResource Btn}"
                      HorizontalAlignment="Left" Margin="0,8,0,0" Padding="10,4" FontSize="11" Visibility="Collapsed"/>
            </StackPanel>
            <CheckBox Name="OptDesktop" IsChecked="True" Content="Put the timeline browser on my desktop" Margin="0,12,0,0"/>
            <CheckBox Name="OptRemote" Content="Keep a second copy off this drive (a dead drive takes the timeline with it)" Margin="0,12,0,0"/>
            <StackPanel Name="RemotePanel" Margin="24,8,0,0" IsEnabled="False">
              <RadioButton Name="RemoteFolder" GroupName="remote" IsChecked="True"
                           Content="A folder - external drive, OneDrive, or a network share. No account needed."/>
              <DockPanel Margin="20,5,0,0">
                <Button Name="BrowseBtn" Content="Choose..." Style="{StaticResource Btn}" DockPanel.Dock="Right" Margin="6,0,0,0"/>
                <TextBox Name="FolderPath"/>
              </DockPanel>
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
$CheckList     = $window.FindName('CheckList')
$OptLogon      = $window.FindName('OptLogon')
$MethodPanel   = $window.FindName('MethodPanel')
$MethodExe     = $window.FindName('MethodExe')
$MethodTask    = $window.FindName('MethodTask')
$OptDesktop    = $window.FindName('OptDesktop')
$OptRemote     = $window.FindName('OptRemote')
$RemotePanel   = $window.FindName('RemotePanel')
$RemoteFolder  = $window.FindName('RemoteFolder')
$RemoteGitHub  = $window.FindName('RemoteGitHub')
$RemoteUrlOpt  = $window.FindName('RemoteUrlOpt')
$FolderPath    = $window.FindName('FolderPath')
$BrowseBtn     = $window.FindName('BrowseBtn')
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
    $glyph, $colour = switch ($State) {
        'ok'   { [char]0x2713, '#7BD88F' }
        'warn' { [char]0x26A0, '#F2C14E' }
        'fail' { [char]0x2717, '#E06C6C' }
        default { [char]0x2022, '#66C0F4' }
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
    $g.FontSize = 13; $g.Width = 20; $g.VerticalAlignment = 'Center'
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

    $ex = Test-ExistingInstall
    if ($ex.Repo) {
        Add-Check 'ok' 'Already set up' "$($ex.Games) game timelines at $MirrorDir"
        $GoBtn.Content = 'Update setup'
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
                $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Steam Save Timeline.lnk'
                New-Shortcut $lnk 'wscript.exe' `
                    "`"$(Join-Path $PSScriptRoot 'run-hidden.vbs')`" steam_save_restore_gui.ps1" `
                    $PSScriptRoot 'Browse and restore Steam Cloud saves'
                Write-Log "[desktop] $lnk"
            } catch { Write-Log "[warn] could not create the desktop shortcut: $_" }
        }

        if ($OptRemote.IsChecked) {
            try {
                $url = $null
                if     ($RemoteFolder.IsChecked) {
                    if ($FolderPath.Text.Trim()) { $url = Connect-FolderCopy $FolderPath.Text.Trim() }
                    else { Write-Log '[copy] no folder chosen, skipped' }
                }
                elseif ($RemoteGitHub.IsChecked) { $url = Connect-GitHubRepo }
                elseif ($RemoteUrl.Text.Trim())  { $url = $RemoteUrl.Text.Trim() }

                if ($url) { Write-Log "[copy] $(Save-SecondCopy $url)" }
            } catch { Write-Log "[warn] second copy: $_" }
        }

        $script:Done = $true
        $GoBtn.Content   = 'Open the timeline browser'
        $GoBtn.IsEnabled = $true
        $StatusText.Text = 'Done. Capture runs from now on; every sync Steam makes becomes a point you can go back to.'
        Write-Log ''
        Write-Log "Mirror: $MirrorDir"
        Write-Log 'Nothing in Steam was modified, the watcher only reads.'
    } catch {
        $StatusText.Text = "Setup failed: $_"
        Write-Log "[error] $_"
        $GoBtn.IsEnabled = $true
    }
}

$OptRemote.Add_Checked({   $RemotePanel.IsEnabled = $true })
$OptRemote.Add_Unchecked({ $RemotePanel.IsEnabled = $false })
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

$BrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Where should the second copy live?'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $FolderPath.Text = $dlg.SelectedPath
        $RemoteFolder.IsChecked = $true
    }
})
$OptLogon.Add_Checked({    $MethodPanel.IsEnabled = $true })
$OptLogon.Add_Unchecked({  $MethodPanel.IsEnabled = $false })

$GoBtn.Add_Click({
    if ($script:Done) {
        Start-Process wscript -ArgumentList "`"$(Join-Path $PSScriptRoot 'run-hidden.vbs')`"", 'steam_save_restore_gui.ps1'
        $window.Close()
        return
    }
    Invoke-Setup
})

# Run the checks after the window has painted, so it does not appear frozen
# while the Steam library is surveyed.
$window.Add_ContentRendered({ Invoke-Checks })
[void]$window.ShowDialog()
