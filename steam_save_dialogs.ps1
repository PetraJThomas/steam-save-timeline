<#
steam_save_dialogs.ps1: themed dialogs, shared by both windows.

MessageBox.Show is a Win32 box with a system icon and grey chrome. It looks
nothing like the rest of the app, and worse, it flattens everything into one
blob of text. The most important dialog here is the restore confirmation,
which has to show a LIST of directories about to be overwritten. That wants
structure, not a paragraph.

Show-ConfirmDialog covers every yes/no and every notice in the project. Pass
$CancelLabel as $null for a single-button notice.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

. (Join-Path $PSScriptRoot 'steam_save_theme.ps1')

function New-Brush([string]$Hex) {
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}

function Show-ConfirmDialog {
    <#
    $Rows takes objects with Head and Sub, rendered as a list. That is what the
    restore confirmation uses for "this root goes to this real directory",
    which is the thing worth reading slowly before saying yes.

    $Tone styles the accent strip and the note: 'info', 'warn' or 'danger'.
    #>
    param(
        $Owner,
        [string]$Title,
        [string]$Headline,
        [string]$Body,
        [string]$RowsCaption,
        $Rows,
        [string]$Note,
        [ValidateSet('info', 'warn', 'danger')] [string]$Tone = 'info',
        [string]$ConfirmLabel = 'Continue',
        [string]$CancelLabel  = 'Cancel'
    )

    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="540" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="#0F1319"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
$SteamSaveTheme
  <Border BorderThickness="0,3,0,0" x:Name="Strip">
    <StackPanel Margin="24,20,24,20">
      <StackPanel Orientation="Horizontal">
        <TextBlock Name="ToneIcon" Style="{StaticResource Icon}" FontSize="19" Margin="0,0,11,0"/>
        <TextBlock Name="HeadText" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"
                   VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock Name="BodyText" Margin="0,7,0,0" FontSize="12.5" TextWrapping="Wrap"
                 Foreground="{StaticResource Muted}"/>

      <Border Name="RowsBox" Margin="0,16,0,0" Background="{StaticResource Panel}"
              BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="13,11">
        <StackPanel>
          <TextBlock Name="RowsCap" FontSize="9.5" FontWeight="SemiBold" Foreground="{StaticResource Muted}"/>
          <ItemsControl Name="RowList" Margin="0,8,0,0">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <StackPanel Margin="0,0,0,9">
                  <TextBlock Text="{Binding Head}" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                  <TextBlock Text="{Binding Sub}" FontSize="11.5" Margin="0,2,0,0"
                             FontFamily="Consolas" TextWrapping="Wrap"
                             Foreground="{StaticResource Muted}"/>
                </StackPanel>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </StackPanel>
      </Border>

      <TextBlock Name="NoteText" Margin="0,15,0,0" FontSize="11.5" TextWrapping="Wrap"/>

      <DockPanel Margin="0,20,0,0" LastChildFill="False">
        <Button Name="OkBtn" Style="{StaticResource BtnPrimary}" DockPanel.Dock="Right" Margin="8,0,0,0"/>
        <Button Name="NoBtn" Style="{StaticResource Btn}" DockPanel.Dock="Right"/>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($dx))
    if ($Owner) { $dlg.Owner = $Owner } else { $dlg.WindowStartupLocation = 'CenterScreen' }
    $dlg.Title = $Title

    # Colour and glyph carry the same signal, so it still reads without colour.
    $accent, $glyph = switch ($Tone) {
        'warn'   { '#F2C14E', [char]0xE7BA }   # warning triangle
        'danger' { '#E06C6C', [char]0xE711 }   # cancel
        default  { '#66C0F4', [char]0xE946 }   # info
    }
    $dlg.FindName('Strip').BorderBrush  = New-Brush $accent
    $toneIcon = $dlg.FindName('ToneIcon')
    $toneIcon.Text       = [string]$glyph
    $toneIcon.Foreground = New-Brush $accent
    $dlg.FindName('HeadText').Text      = $Headline

    $bodyBlock = $dlg.FindName('BodyText')
    if ($Body) { $bodyBlock.Text = $Body } else { $bodyBlock.Visibility = 'Collapsed' }

    $rowsBox = $dlg.FindName('RowsBox')
    if ($Rows -and @($Rows).Count -gt 0) {
        $dlg.FindName('RowsCap').Text = $RowsCaption
        $dlg.FindName('RowList').ItemsSource = @($Rows)
    } else {
        $rowsBox.Visibility = 'Collapsed'
    }

    $noteBlock = $dlg.FindName('NoteText')
    if ($Note) {
        $noteBlock.Text = $Note
        $noteBlock.Foreground = if ($Tone -eq 'info') { $dlg.FindResource('Muted') } else { New-Brush $accent }
    } else {
        $noteBlock.Visibility = 'Collapsed'
    }

    $ok = $dlg.FindName('OkBtn')
    $no = $dlg.FindName('NoBtn')
    $ok.Content   = $ConfirmLabel
    $ok.IsDefault = $true
    $ok.Add_Click({ $dlg.DialogResult = $true })
    if ($CancelLabel) {
        $no.Content  = $CancelLabel
        $no.IsCancel = $true
        $no.Add_Click({ $dlg.DialogResult = $false })
    } else {
        $no.Visibility = 'Collapsed'
        $ok.IsCancel   = $true     # Esc closes a notice that has nothing to decline
    }

    return [bool]$dlg.ShowDialog()
}
