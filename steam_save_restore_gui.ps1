<#
steam_save_restore_gui.ps1: timeline browser, save branches, and restore.

Reads games.json + the per-game branches written by steam_save_watcher.ps1.
Every branch holds exactly one game (see steam_save_timelines.ps1), so a game's
history is just `git log game/<appid>/main`.

Pick a game, pick one of its timelines, pick a point:
  Restore        load that point back into Steam. The restore is committed on
                 top of whichever timeline is active, roll-forward, so the
                 state you are replacing stays in history.
  Branch / Diverge Save
                 start a new save branch at that point and make it active.
                 New syncs go there; main is left exactly as it was.
  Play this one  make another timeline active and load its latest save.
  Make canonical copy a save branch's current state onto main as a new commit,
                 then go back to playing main. Never a rebase or a merge.

The point at which a save branch left main is marked DIVERGED HERE, so
"roll back to before I ever diverged" is one Restore on that row.

Run:  powershell -ExecutionPolicy Bypass -File steam_save_restore_gui.ps1
#>

# ---------------- config ----------------
$MirrorDir = Join-Path $env:USERPROFILE 'steam-save-history'
# ----------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

. (Join-Path $PSScriptRoot 'steam_save_theme.ps1')
. (Join-Path $PSScriptRoot 'steam_save_roots.ps1')
. (Join-Path $PSScriptRoot 'steam_save_timelines.ps1') # supplies Invoke-Git / Get-GitOutput
Initialize-Timelines $MirrorDir

function New-Brush([string]$Hex) {
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}
# One colour per kind of event, so a timeline can be read at a glance.
$script:KindBrush = @{
    SYNC      = New-Brush '#66C0F4'   # Steam actually moved data
    SNAPSHOT  = New-Brush '#5E6E84'   # a sweep found this on disk
    RESTORE   = New-Brush '#F2C14E'
    CANONICAL = New-Brush '#7BD88F'
    CREATED   = New-Brush '#4A5666'
}

function Get-Timeline([string]$AppId, [string]$Branch) {
    # One branch per game, so no grep over a shared log is needed.
    $fork = Get-ForkPoint $AppId $Branch
    Get-GitOutput @('log', $Branch, '--format=%H|%aI|%s') | ForEach-Object {
        $h, $date, $subject = ([string]$_) -split '\|', 3
        if (-not $h) { return }

        # Subjects are "[appid] Game Name: <verb> ...". Game names contain
        # colons ("Cities: Skylines II"), so match on the verb, greedily, to
        # land on the last colon rather than the first.
        $kind = 'SYNC'; $detail = ''
        if     ($subject -match '^.*:\s*RESTORE to\s+(\S+)')            { $kind = 'RESTORE';   $detail = "to $($Matches[1])" }
        elseif ($subject -match '^.*:\s*CANONICAL from\s+(.+)$')        { $kind = 'CANONICAL'; $detail = "from $($Matches[1])" }
        elseif ($subject -match '^.*:\s*snapshot at\s+\S+\s+\S+\s*(.*)$') { $kind = 'SNAPSHOT'; $detail = $Matches[1] }
        elseif ($subject -match '^.*:\s*sync at\s+\S+\s+\S+\s*(.*)$')     { $kind = 'SYNC';     $detail = $Matches[1] }
        elseif ($subject -match 'timeline created')                     { $kind = 'CREATED' }
        $detail = ($detail -replace '^\((.*)\)$', '$1').Trim()

        $isFork = [bool]($fork -and $h -eq $fork)
        [pscustomobject]@{
            Hash      = $h
            When      = ([datetime]$date).ToString('yyyy-MM-dd  HH:mm')
            Kind      = $kind
            KindBrush = $script:KindBrush[$kind]
            Detail    = $detail
            IsFork    = $isFork
            ForkVis   = $(if ($isFork) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
            Label     = "{0}  {1} {2}" -f ([datetime]$date).ToString('yyyy-MM-dd HH:mm'), $kind, $detail
        }
    }
}

function Show-BranchDialog($Owner, [string]$AppId, [string]$GameName, [string]$PointLabel) {
    <#
    Name a new save branch. Its own themed window rather than
    Microsoft.VisualBasic's InputBox, which is an unstyled Win32 box looking
    nothing like the rest of the app. It also does what an InputBox cannot:
    show the name that will actually be used, and refuse a reserved or
    duplicate one while you are typing instead of after you commit to it.
    #>
    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Branch this save" Width="500" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#0F1319" ShowInTaskbar="False"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
$SteamSaveTheme
  <StackPanel Margin="24,20,24,20">
    <TextBlock Text="Branch this save" FontSize="17" FontWeight="SemiBold"/>
    <TextBlock Name="SubText" Margin="0,6,0,0" FontSize="12" TextWrapping="Wrap"
               Foreground="{StaticResource Muted}"/>

    <Border Margin="0,16,0,0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
            BorderThickness="1" CornerRadius="6" Padding="13,10">
      <StackPanel>
        <TextBlock Text="STARTS FROM" FontSize="9.5" FontWeight="SemiBold" Foreground="{StaticResource Muted}"/>
        <TextBlock Name="PointText" Margin="0,6,0,0" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <TextBlock Text="CALL IT" FontSize="9.5" FontWeight="SemiBold" Margin="0,18,0,0"
               Foreground="{StaticResource Muted}"/>
    <TextBox Name="NameBox" Margin="0,7,0,0" FontSize="13.5" Padding="9,7"/>
    <TextBlock Name="HintText" Margin="0,8,0,0" FontSize="11" TextWrapping="Wrap"
               Foreground="{StaticResource Muted}"/>

    <DockPanel Margin="0,20,0,0" LastChildFill="False">
      <Button Name="OkBtn" Content="Create branch" Style="{StaticResource BtnPrimary}"
              DockPanel.Dock="Right" Margin="8,0,0,0" IsEnabled="False"/>
      <Button Name="CancelBtn" Content="Cancel" Style="{StaticResource Btn}" DockPanel.Dock="Right"/>
    </DockPanel>
  </StackPanel>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($dx))
    if ($Owner) { $dlg.Owner = $Owner } else { $dlg.WindowStartupLocation = 'CenterScreen' }
    $sub       = $dlg.FindName('SubText')
    $point     = $dlg.FindName('PointText')
    $box       = $dlg.FindName('NameBox')
    $hint      = $dlg.FindName('HintText')
    $ok        = $dlg.FindName('OkBtn')
    $cancel    = $dlg.FindName('CancelBtn')

    $sub.Text        = "New syncs for $GameName go to this branch. The timeline you are on now is left exactly as it is, so you can come back to it."
    $point.Text      = $PointLabel
    $hint.Text       = 'Whatever this save branch should be called, in a few words.'
    $ok.IsDefault    = $true
    $cancel.IsCancel = $true

    $script:branchName = $null
    $muted = $dlg.FindResource('Muted')
    $good  = $dlg.FindResource('Good')
    $bad   = New-Brush '#E06C6C'

    $validate = {
        $typed = $box.Text.Trim()
        if (-not $typed) {
            $hint.Foreground = $muted
            $hint.Text = 'Whatever this save branch should be called, in a few words.'
            $ok.IsEnabled = $false
            return
        }
        $slug = ConvertTo-TimelineSlug $typed
        if ($slug -in @('main', 'daily')) {
            $hint.Foreground = $bad
            $hint.Text = "'$slug' is a reserved name. Try something else."
            $ok.IsEnabled = $false
            return
        }
        if (Test-Timeline "game/$AppId/$slug") {
            $hint.Foreground = $bad
            $hint.Text = "$GameName already has a branch called '$slug'."
            $ok.IsEnabled = $false
            return
        }
        $hint.Foreground = $good
        $hint.Text = "Saved as: $slug"
        $ok.IsEnabled = $true
    }
    $box.Add_TextChanged($validate)
    $ok.Add_Click({ $script:branchName = $box.Text; $dlg.DialogResult = $true })
    $cancel.Add_Click({ $dlg.DialogResult = $false })
    $dlg.Add_ContentRendered({ $box.Focus() })

    if ($dlg.ShowDialog()) { return $script:branchName }
    return $null
}

function Test-SteamRunning { [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue) }

function Close-Steam([string]$SteamRoot) {
    & (Join-Path $SteamRoot 'steam.exe') -shutdown
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-SteamRunning)) { return $true }
    }
    return $false
}

function Get-UserdataAppDir([string]$AppId, [string]$SteamRoot) {
    $uid = Get-ChildItem (Join-Path $SteamRoot 'userdata') -Directory |
           Where-Object { Test-Path (Join-Path $_.FullName $AppId) } |
           Select-Object -First 1
    if ($uid) { return (Join-Path $uid.FullName $AppId) }
    return $null
}

function Get-RestorePlan([string]$AppId, [string]$Hash, [string]$SteamRoot) {
    <#
    Every destination the restore would write to, read out of the target commit
    (git ls-tree) so it can be shown before anything is touched. A root whose
    real directory cannot be resolved now comes back with Dest = $null and is
    reported rather than guessed at.
    #>
    $appDir  = Get-UserdataAppDir $AppId $SteamRoot
    $entries = @(Get-GitOutput @('ls-tree', '--name-only', $Hash, "$AppId/"))
    $plan    = @()

    if ($entries -contains "$AppId/remote") {
        $dest = $null
        if ($appDir) { $dest = Join-Path $appDir 'remote' }
        $plan += [pscustomobject]@{ Root = 'remote'; Source = (Join-Path $MirrorDir "$AppId\remote"); Dest = $dest }
    }

    if ($entries -contains "$AppId/roots") {
        # roots.json records where each root pointed when the snapshot was taken;
        # it is the fallback when the live lookup fails (game uninstalled, say).
        $recorded = @{}
        $rj = Get-GitOutput @('show', "${Hash}:$AppId/roots.json")
        if ($rj) {
            try {
                (($rj -join "`n") | ConvertFrom-Json).PSObject.Properties |
                    ForEach-Object { $recorded[$_.Name] = $_.Value }
            } catch {}
        }
        foreach ($e in @(Get-GitOutput @('ls-tree', '--name-only', $Hash, "$AppId/roots/"))) {
            $rootName = Split-Path ([string]$e) -Leaf
            $dest = Resolve-SteamRootBase -Root $rootName -AppId $AppId -SteamRoot $SteamRoot -AppDir $appDir
            if (-not $dest -and $recorded.ContainsKey($rootName)) { $dest = $recorded[$rootName] }
            $plan += [pscustomobject]@{
                Root   = $rootName
                Source = (Join-Path $MirrorDir "$AppId\roots\$rootName")
                Dest   = $dest
            }
        }
    }
    return $plan
}

function Restore-Save([string]$AppId, [string]$Hash, [string]$GameName, [string]$SteamRoot, $Plan) {
    # 1. Steam-running gate
    if (Test-SteamRunning) {
        $r = [System.Windows.MessageBox]::Show(
            "Steam is currently running.`n`nRestoring while Steam is open risks the cloud syncing right back over your restored files before you get the conflict prompt.`n`nClose Steam now and continue?",
            'Steam is running', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return 'Cancelled. Close Steam and try again.' }
        if (-not (Close-Steam $SteamRoot)) { return 'Steam did not shut down in time. Close it manually, then retry.' }
    }

    # 2. Roll the mirror to the chosen point, then commit that onto whichever
    #    timeline is active. The state being replaced stays in history.
    if (-not (Expand-AppTree $AppId $Hash)) { return 'Could not read that point out of git.' }
    $branch = Get-ActiveTimeline $AppId
    New-AppCommit $AppId $branch "[$AppId] ${GameName}: RESTORE to $($Hash.Substring(0,8))" | Out-Null

    # 3. Copy the restored files back to every destination in the plan.
    #    Overwrite-in-place, never delete: some of these are game install
    #    directories, and only the files Steam actually syncs belong to us.
    $done    = @()
    $skipped = @()
    foreach ($p in $Plan) {
        if (-not $p.Dest)               { $skipped += "$($p.Root) (no path on this PC)"; continue }
        if (-not (Test-Path $p.Source)) { $skipped += "$($p.Root) (not in that commit)"; continue }
        New-Item -ItemType Directory -Path $p.Dest -Force | Out-Null
        Copy-Item (Join-Path $p.Source '*') $p.Dest -Recurse -Force
        $done += $p.Root
    }
    if ($done.Count -eq 0) { return "Nothing was restored: no usable destination. $($skipped -join '; ')" }

    $msg = "Restored $GameName to $($Hash.Substring(0,8)): $($done -join ', ')."
    if ($skipped.Count -gt 0) { $msg += " Skipped: $($skipped -join '; ')." }
    return "$msg`nStart Steam, launch the game, and if a sync conflict appears choose LOCAL files."
}

function Invoke-RestoreFlow($Game, [string]$Hash, [string]$Label, [string]$SteamRoot) {
    # Show the real destinations first, a restore can write outside Steam's
    # own folders (AppData, Documents, the game's install directory).
    $plan = @(Get-RestorePlan $Game.AppId $Hash $SteamRoot)
    if ($plan.Count -eq 0) { return 'Nothing to restore at that point.' }

    $lines = foreach ($p in $plan) {
        if ($p.Dest) { "  $($p.Root)  ->  $($p.Dest)" } else { "  $($p.Root)  ->  (unresolved, will be skipped)" }
    }
    $active = Get-TimelineLabel $Game.AppId (Get-ActiveTimeline $Game.AppId)
    $confirm = [System.Windows.MessageBox]::Show(
        "Restore $($Game.Name) to:`n$Label`n`nThis will overwrite files in:`n$($lines -join "`n")`n`nThe restore is committed on the '$active' timeline; the state it replaces stays in history.",
        'Confirm restore', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return 'Cancelled.' }

    return (Restore-Save $Game.AppId $Hash $Game.Name $SteamRoot $plan)
}

# ---------------- UI ----------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam Save Timeline" Width="1060" Height="660" MinWidth="880" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#0F1319"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
$SteamSaveTheme

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Border Grid.Row="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="18,13">
      <DockPanel LastChildFill="False">
        <TextBlock Text="Steam Save Timeline" FontSize="17" FontWeight="SemiBold" DockPanel.Dock="Left"/>
        <TextBlock Name="SubtitleText" DockPanel.Dock="Right" VerticalAlignment="Center"
                   FontSize="11" Foreground="{StaticResource Muted}"/>
      </DockPanel>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="250"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- games -->
      <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <DockPanel Margin="10,12,10,10">
          <TextBlock DockPanel.Dock="Top" Text="GAMES" FontSize="10" FontWeight="SemiBold"
                     Foreground="{StaticResource Muted}" Margin="6,0,0,8"/>
          <ListBox Name="GameList" Style="{StaticResource List}" ItemContainerStyle="{StaticResource Row}">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <StackPanel>
                  <TextBlock Text="{Binding Name}" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding AppId}" FontSize="10" Foreground="{StaticResource Muted}" Margin="0,1,0,0"/>
                </StackPanel>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>

      <!-- timeline -->
      <DockPanel Grid.Column="1" Margin="18,14,18,8">
        <StackPanel DockPanel.Dock="Top">
          <DockPanel LastChildFill="False">
            <TextBlock Name="GameTitle" Text="Select a game" FontSize="15" FontWeight="SemiBold" DockPanel.Dock="Left"/>
            <TextBlock Name="PlayingText" DockPanel.Dock="Left" Margin="12,0,0,0" VerticalAlignment="Center"
                       FontSize="11" Foreground="{StaticResource Good}"/>
          </DockPanel>

          <DockPanel Margin="0,12,0,10" LastChildFill="False">
            <WrapPanel Name="TimelineBar" DockPanel.Dock="Left" Orientation="Horizontal"/>
            <Button Name="CanonicalBtn" Content="Make canonical" Style="{StaticResource Btn}" DockPanel.Dock="Right" Margin="6,0,0,0" IsEnabled="False"/>
            <Button Name="SwitchBtn"    Content="Play this one"  Style="{StaticResource Btn}" DockPanel.Dock="Right" Margin="6,0,0,0" IsEnabled="False"/>
            <Button Name="ForkBtn"      Content="Branch / Diverge Save" Style="{StaticResource Btn}" DockPanel.Dock="Right" Padding="16,7" IsEnabled="False"/>
          </DockPanel>
        </StackPanel>

        <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="6">
         <Grid>
          <TextBlock Name="EmptyHint" Visibility="Collapsed" Foreground="{StaticResource Muted}"
                     FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"
                     TextAlignment="Center" Text="Nothing recorded on this timeline yet."/>
          <ListBox Name="TimelineList" Style="{StaticResource List}" ItemContainerStyle="{StaticResource Row}">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Background="{Binding KindBrush}" CornerRadius="3"
                          Padding="7,2" MinWidth="78">
                    <TextBlock Text="{Binding Kind}" FontSize="9.5" FontWeight="Bold" Foreground="#0B1017"
                               HorizontalAlignment="Center"/>
                  </Border>
                  <TextBlock Grid.Column="1" Text="{Binding When}" Margin="12,0,0,0" VerticalAlignment="Center"
                             FontFamily="Consolas" FontSize="12" Foreground="{StaticResource Muted}"/>
                  <TextBlock Grid.Column="2" Text="{Binding Detail}" Margin="14,0,8,0" VerticalAlignment="Center"
                             FontSize="12" TextTrimming="CharacterEllipsis"/>
                  <Border Grid.Column="3" Visibility="{Binding ForkVis}" CornerRadius="3" Padding="7,2"
                          Background="#2B2039" BorderBrush="{StaticResource ForkC}" BorderThickness="1">
                    <TextBlock Text="DIVERGED HERE" FontSize="9.5" FontWeight="Bold" Foreground="{StaticResource ForkC}"/>
                  </Border>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
         </Grid>
        </Border>
      </DockPanel>
    </Grid>

    <!-- footer -->
    <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="18,12">
      <DockPanel LastChildFill="True">
        <Button Name="RestoreBtn" Content="Restore selected point" Style="{StaticResource BtnPrimary}"
                DockPanel.Dock="Right" Margin="14,0,0,0" IsEnabled="False"/>
        <TextBlock Name="StatusText" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="12"
                   Foreground="{StaticResource Muted}" Text="Select a game, then a point in its timeline."/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

$window       = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$GameList     = $window.FindName('GameList')
$TimelineBar  = $window.FindName('TimelineBar')
$TimelineList = $window.FindName('TimelineList')
$RestoreBtn   = $window.FindName('RestoreBtn')
$ForkBtn      = $window.FindName('ForkBtn')
$SwitchBtn    = $window.FindName('SwitchBtn')
$CanonicalBtn = $window.FindName('CanonicalBtn')
$StatusText   = $window.FindName('StatusText')
$EmptyHint    = $window.FindName('EmptyHint')
$GameTitle    = $window.FindName('GameTitle')
$PlayingText  = $window.FindName('PlayingText')
$SubtitleText = $window.FindName('SubtitleText')

$steamRoot = Find-SteamRoot
$gamesPath = Join-Path $MirrorDir 'games.json'
$games     = @{}
if (Test-Path $gamesPath) {
    (Get-Content $gamesPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $games[$_.Name] = $_.Value }
}
$appIds = @(Get-ChildItem $MirrorDir -Directory | Where-Object Name -match '^\d+$' | Select-Object -ExpandProperty Name)
$script:loading         = $false
$script:CurrentTimeline = $null

foreach ($id in ($appIds | Sort-Object { if ($games[$_]) { $games[$_] } else { "zzz$_" } })) {
    $name = if ($games[$id]) { $games[$id] } else { "app $id" }
    [void]$GameList.Items.Add([pscustomobject]@{ AppId = $id; Name = $name })
}
$SubtitleText.Text = "$($GameList.Items.Count) games mirrored   ·   $MirrorDir"

function Update-TimelineBar($Game) {
    $script:loading = $true
    $TimelineBar.Children.Clear()
    $active  = Get-ActiveTimeline $Game.AppId
    $checkMe = $null

    foreach ($t in (Get-GameTimelines $Game.AppId)) {
        $pill = New-Object System.Windows.Controls.RadioButton
        $pill.Style     = $window.FindResource('Pill')
        $pill.GroupName = 'timelines'
        # a dot marks the timeline being played, which is not always the one
        # being looked at
        $pill.Content   = if ($t.IsActive) { "$($t.Label)  " + [char]0x25CF } else { $t.Label }
        $pill.Tag       = $t
        $pill.Add_Checked({
            if ($script:loading) { return }
            $g = $GameList.SelectedItem
            if ($g) { Update-CommitList $g $this.Tag }
        })
        [void]$TimelineBar.Children.Add($pill)
        if ($t.Branch -eq $active) { $checkMe = $pill }
    }
    if (-not $checkMe -and $TimelineBar.Children.Count -gt 0) { $checkMe = $TimelineBar.Children[0] }

    $GameTitle.Text   = $Game.Name
    $PlayingText.Text = if ($active) { [char]0x25CF + ' playing ' + (Get-TimelineLabel $Game.AppId $active) } else { '' }

    $script:loading = $false
    if ($checkMe) { $checkMe.IsChecked = $true; Update-CommitList $Game $checkMe.Tag }
}

function Update-CommitList($Game, $Tl) {
    $script:CurrentTimeline = $Tl
    $TimelineList.Items.Clear()
    $RestoreBtn.IsEnabled = $false
    $ForkBtn.IsEnabled    = $false
    if (-not $Tl) { return }

    foreach ($c in (Get-Timeline $Game.AppId $Tl.Branch)) { [void]$TimelineList.Items.Add($c) }
    $EmptyHint.Visibility = if ($TimelineList.Items.Count -eq 0) {
        [System.Windows.Visibility]::Visible
    } else {
        [System.Windows.Visibility]::Collapsed
    }

    $SwitchBtn.IsEnabled    = (-not $Tl.IsActive -and $Tl.Kind -ne 'daily')
    $CanonicalBtn.IsEnabled = ($Tl.Kind -eq 'fork')

    $msg = "$($TimelineList.Items.Count) point(s) on '$($Tl.Label)'."
    if     ($Tl.Kind -eq 'daily') { $msg += '  Daily snapshots are an archive. Restoring from here lands on the timeline you are playing.' }
    elseif ($Tl.Kind -eq 'fork')  { $msg += '  The DIVERGED HERE row is where this branch left main. Restore it to undo the divergence.' }
    if (-not $Tl.IsActive -and $Tl.Kind -ne 'daily') { $msg += '  You are not currently playing this one.' }
    $StatusText.Text = $msg
}

function Reload($Game) { Update-TimelineBar $Game }

$GameList.Add_SelectionChanged({
    $sel = $GameList.SelectedItem
    if (-not $sel) { return }
    Reload $sel
})

$TimelineList.Add_SelectionChanged({
    $has = ($null -ne $TimelineList.SelectedItem)
    $RestoreBtn.IsEnabled = $has
    $ForkBtn.IsEnabled    = $has
})

$RestoreBtn.Add_Click({
    $game = $GameList.SelectedItem
    $c    = $TimelineList.SelectedItem
    if (-not $game -or -not $c) { return }
    $StatusText.Text = 'Restoring...'
    $StatusText.Text = Invoke-RestoreFlow $game $c.Hash $c.Label $steamRoot
    Reload $game
})

$ForkBtn.Add_Click({
    $game = $GameList.SelectedItem
    $c    = $TimelineList.SelectedItem
    $tl   = $script:CurrentTimeline
    if (-not $game -or -not $c -or -not $tl) { return }

    $name = Show-BranchDialog $window $game.AppId $game.Name $c.Label
    if (-not $name) { return }

    $prevActive = Get-ActiveTimeline $game.AppId
    $prevTip    = Get-GitLine @('rev-parse', $prevActive)
    $r = New-TimelineFork $game.AppId $name $c.Hash
    if (-not $r.Ok) { $StatusText.Text = $r.Message; return }

    if ($c.Hash -eq $prevTip) {
        $StatusText.Text = "Timeline '$($r.Slug)' created from the current save and is now active. Play on, new syncs go here, main is untouched."
    } else {
        $load = [System.Windows.MessageBox]::Show(
            "Timeline '$($r.Slug)' created and is now active.`n`nIt starts at an earlier point than your current save. Load that save into Steam now?",
            'Load the fork point?', 'YesNo', 'Question')
        if ($load -eq 'Yes') { $StatusText.Text = Invoke-RestoreFlow $game $c.Hash $c.Label $steamRoot }
        else { $StatusText.Text = "Timeline '$($r.Slug)' is active, but Steam still holds your other save. Restore that point when you want to play it." }
    }
    Reload $game
})

$SwitchBtn.Add_Click({
    $game = $GameList.SelectedItem
    $tl   = $script:CurrentTimeline
    if (-not $game -or -not $tl) { return }
    $tip = Get-GitLine @('rev-parse', $tl.Branch)
    if (-not $tip) { $StatusText.Text = 'That timeline has no commits yet.'; return }

    $confirm = [System.Windows.MessageBox]::Show(
        "Play '$($tl.Label)' for $($game.Name)?`n`nNew syncs will be recorded there, and its latest save will be loaded into Steam.",
        'Switch timeline', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    Set-ActiveTimeline $game.AppId $tl.Branch
    $StatusText.Text = Invoke-RestoreFlow $game $tip "latest point on '$($tl.Label)'" $steamRoot
    Reload $game
})

$CanonicalBtn.Add_Click({
    $game = $GameList.SelectedItem
    $tl   = $script:CurrentTimeline
    if (-not $game -or -not $tl) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        "Make '$($tl.Label)' the canonical save for $($game.Name)?`n`nIts current state is committed onto main as a new point, and main goes back to being the timeline you play. Nothing is rewritten, main keeps its history and '$($tl.Label)' is kept too.",
        'Make canonical', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $r = Invoke-MakeCanonical $game.AppId $tl.Branch $game.Name
    if (-not $r.Ok) { $StatusText.Text = $r.Message; return }
    $StatusText.Text = if ($r.Commit) {
        "'$($r.From)' is now the canonical save for $($game.Name), committed on main. Your live save already matches it, nothing to load."
    } else {
        "main already held exactly that state for $($game.Name); now playing main again."
    }
    Reload $game
})

if ($GameList.Items.Count -gt 0) { $GameList.SelectedIndex = 0 }   # never open on an empty pane
[void]$window.ShowDialog()
