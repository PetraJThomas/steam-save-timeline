<#
steam_save_theme.ps1: the dark theme, shared by every window in this project.

Held here as a XAML fragment rather than a ResourceDictionary file so it can be
interpolated straight into each window's markup: no external theme assembly, no
extra file to ship, and the Steam Save Timeline Browser and the setup window cannot drift
apart. Inject it with "$SteamSaveTheme" inside a double-quoted here-string.

Palette: near-black ground, two panel greys, Steam-ish blue accent. Even the
scrollbars are retemplated, because the stock ones are light grey and break the
theme instantly.
#>

$SteamSaveTheme = @'
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"     Color="#0F1319"/>
    <SolidColorBrush x:Key="Panel"  Color="#161B23"/>
    <SolidColorBrush x:Key="Panel2" Color="#1D2430"/>
    <SolidColorBrush x:Key="Hover"  Color="#243040"/>
    <SolidColorBrush x:Key="Line"   Color="#2A3341"/>
    <SolidColorBrush x:Key="BtnLine" Color="#5A6A80"/>
    <SolidColorBrush x:Key="Text"   Color="#E8EDF4"/>
    <SolidColorBrush x:Key="Muted"  Color="#93A1B5"/>
    <SolidColorBrush x:Key="Accent" Color="#66C0F4"/>
    <SolidColorBrush x:Key="Good"   Color="#7BD88F"/>
    <SolidColorBrush x:Key="ForkC"  Color="#C792EA"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>

    <!-- buttons -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background"  Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground"  Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BtnLine}"/>
      <Setter Property="FontFamily"  Value="Segoe UI"/>
      <Setter Property="FontSize"    Value="12"/>
      <Setter Property="Padding"     Value="14,7"/>
      <Setter Property="Cursor"      Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="4" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Hover}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#3C4A5C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#161D27"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!--
      The primary button needs its OWN template. Inheriting the one above via
      BasedOn meant its hover trigger set the background to the dark slate
      Hover brush, so the bright blue button turned grey under the cursor.

      Solid bright button, so it shades toward black on hover the way Bootstrap
      does rather than lightening: 30% shade (x0.70) on hover, 45% (x0.55) on
      press. #66C0F4 -> #4786AB -> #386A86. The dark label still clears AA on
      the hover shade (about 4.8:1).
    -->
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Background"  Value="{StaticResource Accent}"/>
      <Setter Property="Foreground"  Value="#0B1017"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontFamily"  Value="Segoe UI"/>
      <Setter Property="FontSize"    Value="12"/>
      <Setter Property="FontWeight"  Value="SemiBold"/>
      <Setter Property="Padding"     Value="18,9"/>
      <Setter Property="Cursor"      Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="pb" CornerRadius="4" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="pb" Property="Background"  Value="#4786AB"/>
                <Setter TargetName="pb" Property="BorderBrush" Value="#4786AB"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="pb" Property="Background"  Value="#4786AB"/>
                <Setter TargetName="pb" Property="BorderBrush" Value="#27536B"/>
                <Setter TargetName="pb" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!--
      Icons come from the system icon font: Segoe Fluent Icons ships with
      Windows 11, Segoe MDL2 Assets with 10. Naming both means nothing to
      install and no tofu on either. Every glyph used was rendered and eyeballed
      before being committed, because a wrong codepoint is a blank box.
    -->
    <Style x:Key="Icon" TargetType="TextBlock" BasedOn="{StaticResource {x:Type TextBlock}}">
      <Setter Property="FontFamily"        Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- timeline pills -->
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="Margin"     Value="0,0,8,0"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="12" Background="{StaticResource Panel2}"
                    BorderBrush="{StaticResource BtnLine}" BorderThickness="1" Padding="13,5">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Hover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background"  Value="#15303F"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Accent}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    </Style>

    <!-- scrollbars: the stock ones are light grey and break the theme -->
    <Style x:Key="SbThumb" TargetType="Thumb">
      <Setter Property="MinHeight" Value="28"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" CornerRadius="4" Background="#39465A" Margin="3,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="t" Property="Background" Value="#4C5C74"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="11"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource SbThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- form controls (used by the setup window) -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="12.5"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background"      Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground"      Value="{StaticResource Text}"/>
      <Setter Property="CaretBrush"      Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush"     Value="{StaticResource BtnLine}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="7,5"/>
      <Setter Property="FontFamily"      Value="Segoe UI"/>
      <Setter Property="FontSize"        Value="12"/>
    </Style>

    <!-- lists -->
    <Style x:Key="List" TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <Style x:Key="Row" TargetType="ListBoxItem">
      <Setter Property="Padding"    Value="10,7"/>
      <Setter Property="Margin"     Value="0,1"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" CornerRadius="4" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Panel2}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1B3247"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
'@

<#
The app icon: Windows' own "previous versions" icon from imageres.dll,
extracted at runtime so nothing has to ship and nothing can go missing.

Two things ruled others out, both measured rather than guessed:

  The cloud nearby is the OneDrive glyph. This tool offers OneDrive as a
  backup destination, so that icon would read as OneDrive sync status.

  The sync arrows nearby are an OVERLAY BADGE: a 15x15 glyph sitting in the
  corner of a 32x32 canvas, 22% fill, offset -9,+8. Windows scales the whole
  canvas down for a title bar, so the badge lands as a tiny dot. Anything used
  as an app icon has to fill its canvas; this one is 81% and centred.

Mind the numbering. ExtractIconEx indexes from 0 and AutoHotkey's IconNumber
from 1, so the SAME icon is 142 here and 143 in SteamSaveTimeline.ahk. Verified
by rendering both, not by reading docs.
#>
$script:AppIconSource = $null

function Get-AppIcon {
    if ($script:AppIconSource) { return $script:AppIconSource }
    try {
        if (-not ('SstIcon' -as [type])) {
            Add-Type @"
using System;using System.Runtime.InteropServices;
public class SstIcon {
  [DllImport("shell32.dll",CharSet=CharSet.Unicode)]
  public static extern int ExtractIconEx(string f,int i,IntPtr[] big,IntPtr[] small,int n);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
}
"@
        }
        $big = New-Object IntPtr[] 1
        [void][SstIcon]::ExtractIconEx("$env:WINDIR\System32\imageres.dll", 142, $big, (New-Object IntPtr[] 1), 1)
        if ($big[0] -ne [IntPtr]::Zero) {
            $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                       $big[0], [System.Windows.Int32Rect]::Empty,
                       [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $src.Freeze()
            [void][SstIcon]::DestroyIcon($big[0])
            $script:AppIconSource = $src
        }
    } catch {
        # decoration only: a missing icon must never stop a window opening
    }
    return $script:AppIconSource
}
