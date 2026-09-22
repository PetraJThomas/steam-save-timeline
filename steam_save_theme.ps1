<#
steam_save_theme.ps1: the dark theme, shared by every window in this project.

Held here as a XAML fragment rather than a ResourceDictionary file so it can be
interpolated straight into each window's markup: no external theme assembly, no
extra file to ship, and the timeline browser and the setup window cannot drift
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
    <SolidColorBrush x:Key="Text"   Color="#E8EDF4"/>
    <SolidColorBrush x:Key="Muted"  Color="#8391A5"/>
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
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
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
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background"  Value="{StaticResource Accent}"/>
      <Setter Property="Foreground"  Value="#0B1017"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight"  Value="SemiBold"/>
      <Setter Property="Padding"     Value="18,9"/>
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
                    BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="13,5">
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
      <Setter Property="BorderBrush"     Value="{StaticResource Line}"/>
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
