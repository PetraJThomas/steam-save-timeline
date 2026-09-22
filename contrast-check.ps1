<#
contrast-check.ps1: WCAG 2.2 AA contrast audit of every piece of UI copy.

Run it after any theme or palette change:
    powershell -ExecutionPolicy Bypass -File contrast-check.ps1

WCAG 2.2 keeps the 2.x contrast maths unchanged, so this implements:

  1.4.3  Contrast (Minimum), AA
         4.5:1 for normal text.
         3:1 for large text, meaning >= 24px, or >= 18.66px AND bold.
         WCAG px are CSS px; WPF device-independent units are also 1/96in,
         so the sizes in the XAML are directly comparable.

  1.4.11 Non-text Contrast, AA
         3:1 for meaningful graphics (icons that carry information) and for
         the visual boundaries of UI components.

Bold means >= 700. Segoe UI SemiBold is 600, so it is deliberately NOT
counted as bold here: that is the conservative reading, and it only ever
makes the check stricter.

The inventory below is hand-maintained and must be extended when UI is
added. A contrast checker that only knows about the palette, rather than
about the text actually drawn on it, proves nothing.
#>

$ErrorActionPreference = 'Stop'

# ---------------- WCAG maths ----------------

function Get-Channel([double]$srgb) {
    if ($srgb -le 0.03928) { return $srgb / 12.92 }
    return [Math]::Pow((($srgb + 0.055) / 1.055), 2.4)
}

function Get-Luminance([string]$hex) {
    $h = $hex.TrimStart('#')
    $r = Get-Channel ([Convert]::ToInt32($h.Substring(0, 2), 16) / 255)
    $g = Get-Channel ([Convert]::ToInt32($h.Substring(2, 2), 16) / 255)
    $b = Get-Channel ([Convert]::ToInt32($h.Substring(4, 2), 16) / 255)
    return (0.2126 * $r) + (0.7152 * $g) + (0.0722 * $b)
}

function Get-Contrast([string]$fg, [string]$bg) {
    $a = Get-Luminance $fg
    $b = Get-Luminance $bg
    if ($b -gt $a) { $t = $a; $a = $b; $b = $t }
    return ($a + 0.05) / ($b + 0.05)
}

function Get-Required([double]$Size, [bool]$Bold, [string]$Kind) {
    if ($Kind -eq 'decorative') { return 0.0 }                    # not in scope
    if ($Kind -eq 'graphic') { return 3.0 }                       # 1.4.11
    if ($Size -ge 24) { return 3.0 }                              # 1.4.3 large
    if ($Size -ge 18.66 -and $Bold) { return 3.0 }
    return 4.5
}

# ---------------- palette ----------------

$C = @{
    Bg        = '#0F1319'; Panel  = '#161B23'; Panel2 = '#1D2430'
    Hover     = '#243040'; Line   = '#2A3341'; Sel    = '#1B3247'; BtnLine = '#5A6A80'
    PillOn    = '#15303F'; LogBg  = '#0B0E13'; ForkBg = '#2B2039'
    Text      = '#E8EDF4'; Muted  = '#93A1B5'; Accent = '#66C0F4'
    Good      = '#7BD88F'; Warn   = '#F2C14E'; Bad    = '#E06C6C'; Fork = '#C792EA'
    OnAccent  = '#0B1017'
    AccentHov = '#4786AB'; AccentPr = '#4786AB'
    KindSync  = '#66C0F4'; KindSnap = '#55637A'; KindRest = '#F2C14E'
    KindCanon = '#7BD88F'; KindMade = '#4A5666'
}

# ---------------- what is actually drawn ----------------
# Where a row sits on a surface that changes (a list row is transparent over
# the panel, tinted on hover, tinted again when selected) the worst case is
# the one listed.

$Checks = @(
    # --- main window: header and chrome
    @{ W='browser'; T='Title "Steam Save Timeline"';  Fg=$C.Text;   Bg=$C.Panel;  S=17;   B=$false }
    @{ W='browser'; T='Subtitle (game count, path)';  Fg=$C.Muted;  Bg=$C.Panel;  S=11;   B=$false }
    @{ W='browser'; T='GAMES caption';                Fg=$C.Muted;  Bg=$C.Panel;  S=10;   B=$false }
    @{ W='browser'; T='Games caption icon';           Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false; K='graphic' }

    # --- game list
    @{ W='browser'; T='Game name';                    Fg=$C.Text;   Bg=$C.Panel;  S=12.5; B=$false }
    @{ W='browser'; T='Game name (selected row)';     Fg=$C.Text;   Bg=$C.Sel;    S=12.5; B=$false }
    @{ W='browser'; T='Game appid';                   Fg=$C.Muted;  Bg=$C.Panel;  S=10;   B=$false }
    @{ W='browser'; T='Game appid (selected row)';    Fg=$C.Muted;  Bg=$C.Sel;    S=10;   B=$false }

    # --- timeline header and controls
    @{ W='browser'; T='Selected game title';          Fg=$C.Text;   Bg=$C.Bg;     S=15;   B=$false }
    @{ W='browser'; T='"playing <timeline>"';         Fg=$C.Good;   Bg=$C.Bg;     S=11;   B=$false }
    @{ W='browser'; T='Pill label (inactive)';        Fg=$C.Muted;  Bg=$C.Panel2; S=12;   B=$false }
    @{ W='browser'; T='Pill label (selected)';        Fg=$C.Accent; Bg=$C.PillOn; S=12;   B=$false }
    @{ W='browser'; T='Pill border (selected)';       Fg=$C.Accent; Bg=$C.Bg;     S=12;   B=$false; K='graphic' }
    @{ W='browser'; T='Button label';                 Fg=$C.Text;   Bg=$C.Panel2; S=12;   B=$false }
    @{ W='browser'; T='Button label (hover)';         Fg=$C.Text;   Bg=$C.Hover;  S=12;   B=$false }
    @{ W='browser'; T='Button icon';                  Fg=$C.Text;   Bg=$C.Panel2; S=13;   B=$false; K='graphic' }
    # 1.4.11 covers boundaries needed to IDENTIFY a component, so the borders of
    # buttons, inputs and pills must clear 3:1. The outline around a static card
    # identifies nothing and operates nothing, so it stays subtle on purpose and
    # is recorded here as decorative rather than quietly dropped from the list.
    @{ W='browser'; T='Button border vs page';        Fg=$C.BtnLine; Bg=$C.Bg;    S=1; B=$false; K='graphic' }
    @{ W='browser'; T='Button border vs panel';       Fg=$C.BtnLine; Bg=$C.Panel; S=1; B=$false; K='graphic' }
    @{ W='browser'; T='Text input border';            Fg=$C.BtnLine; Bg=$C.Panel; S=1; B=$false; K='graphic' }
    @{ W='browser'; T='Card outline (decorative)';    Fg=$C.Line;    Bg=$C.Bg;    S=1; B=$false; K='decorative' }

    # --- timeline rows
    @{ W='browser'; T='Row chevron';                  Fg=$C.Muted;  Bg=$C.Panel;  S=11;   B=$false; K='graphic' }
    @{ W='browser'; T='Badge "SYNC"';                 Fg=$C.OnAccent; Bg=$C.KindSync;  S=9.5; B=$true }
    @{ W='browser'; T='Badge "SNAPSHOT"';             Fg=$C.Text;     Bg=$C.KindSnap;  S=9.5; B=$true }
    @{ W='browser'; T='Badge "RESTORE"';              Fg=$C.OnAccent; Bg=$C.KindRest;  S=9.5; B=$true }
    @{ W='browser'; T='Badge "CANONICAL"';            Fg=$C.OnAccent; Bg=$C.KindCanon; S=9.5; B=$true }
    @{ W='browser'; T='Badge "CREATED"';              Fg=$C.Text;     Bg=$C.KindMade;  S=9.5; B=$true }
    @{ W='browser'; T='Row timestamp';                Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false }
    @{ W='browser'; T='Row timestamp (selected)';     Fg=$C.Muted;  Bg=$C.Sel;    S=12;   B=$false }
    @{ W='browser'; T='Row detail';                   Fg=$C.Text;   Bg=$C.Panel;  S=12;   B=$false }
    @{ W='browser'; T='"DIVERGED HERE" chip';         Fg=$C.Fork;   Bg=$C.ForkBg; S=9.5;  B=$true }

    # --- expanded row (accordion)
    @{ W='browser'; T='File summary line';            Fg=$C.Muted;  Bg=$C.Sel;    S=10.5; B=$false }
    @{ W='browser'; T='File name';                    Fg=$C.Text;   Bg=$C.Sel;    S=11.5; B=$false }
    @{ W='browser'; T='File location';                Fg=$C.Muted;  Bg=$C.Sel;    S=10;   B=$false }
    @{ W='browser'; T='File size';                    Fg=$C.Accent; Bg=$C.Sel;    S=11;   B=$false }
    @{ W='browser'; T='File modified date';           Fg=$C.Muted;  Bg=$C.Sel;    S=11;   B=$false }
    @{ W='browser'; T='Empty-timeline hint';          Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false }

    # --- footer
    @{ W='browser'; T='Status text';                  Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false }
    @{ W='browser'; T='Restore label on accent';      Fg=$C.OnAccent; Bg=$C.Accent;    S=12; B=$true }
    @{ W='browser'; T='Restore label (hover)';        Fg=$C.OnAccent; Bg=$C.AccentHov; S=12; B=$true }
    @{ W='browser'; T='Restore label (pressed)';      Fg=$C.OnAccent; Bg=$C.AccentPr;  S=12; B=$true }
    @{ W='browser'; T='Restore icon on accent';       Fg=$C.OnAccent; Bg=$C.Accent;    S=14; B=$false; K='graphic' }

    # --- branch dialog
    @{ W='branch';  T='Headline';                     Fg=$C.Text;   Bg=$C.Bg;     S=17;   B=$false }
    @{ W='branch';  T='Explanatory body';             Fg=$C.Muted;  Bg=$C.Bg;     S=12;   B=$false }
    @{ W='branch';  T='"STARTS FROM" caption';        Fg=$C.Muted;  Bg=$C.Panel;  S=9.5;  B=$false }
    @{ W='branch';  T='Starting point text';          Fg=$C.Text;   Bg=$C.Panel;  S=12;   B=$false }
    @{ W='branch';  T='"CALL IT" caption';            Fg=$C.Muted;  Bg=$C.Bg;     S=9.5;  B=$false }
    @{ W='branch';  T='Name entry text';              Fg=$C.Text;   Bg=$C.Panel2; S=13.5; B=$false }
    @{ W='branch';  T='Hint, neutral';                Fg=$C.Muted;  Bg=$C.Bg;     S=11;   B=$false }
    @{ W='branch';  T='Hint, accepted';               Fg=$C.Good;   Bg=$C.Bg;     S=11;   B=$false }
    @{ W='branch';  T='Hint, rejected';               Fg=$C.Bad;    Bg=$C.Bg;     S=11;   B=$false }

    # --- confirm dialog
    @{ W='confirm'; T='Headline';                     Fg=$C.Text;   Bg=$C.Bg;     S=17;   B=$false }
    @{ W='confirm'; T='Tone icon, info';              Fg=$C.Accent; Bg=$C.Bg;     S=19;   B=$false; K='graphic' }
    @{ W='confirm'; T='Tone icon, warn';              Fg=$C.Warn;   Bg=$C.Bg;     S=19;   B=$false; K='graphic' }
    @{ W='confirm'; T='Tone icon, danger';            Fg=$C.Bad;    Bg=$C.Bg;     S=19;   B=$false; K='graphic' }
    @{ W='confirm'; T='Body text';                    Fg=$C.Muted;  Bg=$C.Bg;     S=12.5; B=$false }
    @{ W='confirm'; T='"WILL OVERWRITE" caption';     Fg=$C.Muted;  Bg=$C.Panel;  S=9.5;  B=$false }
    @{ W='confirm'; T='Destination root name';        Fg=$C.Text;   Bg=$C.Panel;  S=12;   B=$false }
    @{ W='confirm'; T='Destination path';             Fg=$C.Muted;  Bg=$C.Panel;  S=11.5; B=$false }
    @{ W='confirm'; T='Note, neutral';                Fg=$C.Muted;  Bg=$C.Bg;     S=11.5; B=$false }
    @{ W='confirm'; T='Note, warn';                   Fg=$C.Warn;   Bg=$C.Bg;     S=11.5; B=$false }
    @{ W='confirm'; T='Note, danger';                 Fg=$C.Bad;    Bg=$C.Bg;     S=11.5; B=$false }

    # --- setup window
    @{ W='setup';   T='Title';                        Fg=$C.Text;   Bg=$C.Panel;  S=19;   B=$false }
    @{ W='setup';   T='Subtitle';                     Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false }
    @{ W='setup';   T='Section caption';              Fg=$C.Muted;  Bg=$C.Bg;     S=10;   B=$false }
    @{ W='setup';   T='Check glyph, pass';            Fg=$C.Good;   Bg=$C.Panel;  S=14;   B=$false; K='graphic' }
    @{ W='setup';   T='Check glyph, warn';            Fg=$C.Warn;   Bg=$C.Panel;  S=14;   B=$false; K='graphic' }
    @{ W='setup';   T='Check glyph, fail';            Fg=$C.Bad;    Bg=$C.Panel;  S=14;   B=$false; K='graphic' }
    @{ W='setup';   T='Check label';                  Fg=$C.Text;   Bg=$C.Panel;  S=12.5; B=$false }
    @{ W='setup';   T='Check detail';                 Fg=$C.Muted;  Bg=$C.Panel;  S=11.5; B=$false }
    @{ W='setup';   T='Checkbox label';               Fg=$C.Text;   Bg=$C.Panel;  S=12.5; B=$false }
    @{ W='setup';   T='Radio label';                  Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false }
    @{ W='setup';   T='Radio sub-note';               Fg=$C.Muted;  Bg=$C.Panel;  S=10.5; B=$false }
    @{ W='setup';   T='Privacy note';                 Fg=$C.Good;   Bg=$C.Panel;  S=11;   B=$false }
    @{ W='setup';   T='Remote URL entry';             Fg=$C.Text;   Bg=$C.Panel2; S=12;   B=$false }
    @{ W='setup';   T='Progress log';                 Fg=$C.Muted;  Bg=$C.LogBg;  S=11.5; B=$false }
    @{ W='setup';   T='Status text';                  Fg=$C.Muted;  Bg=$C.Panel;  S=12;   B=$false }
    @{ W='setup';   T='Primary button label';         Fg=$C.OnAccent; Bg=$C.Accent; S=12;  B=$true }
)

# ---------------- lint: text that never gets a colour ----------------
<#
The inventory above says what colour each piece of copy is SUPPOSED to be. It
cannot see a TextBlock that never receives that colour at all, and one slipped
through exactly that way: the destination list in the restore dialog inherited
the Windows default black on a near-black panel, about 1.1:1, while the
inventory happily reported 14.69:1.

The cause is that an implicit `<Style TargetType="TextBlock">` does not reach
inside a DataTemplate. Rows in the browser survived only because ListBoxItem
sets Foreground and that inherits down; an ItemsControl has no such chain.

So: inside a DataTemplate, Foreground is mandatory. This catches any that lack
it, reading whole elements rather than single lines.
#>
function Test-TemplateForegrounds([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $bad  = @()
    foreach ($tpl in [regex]::Matches($text, '(?s)<DataTemplate>(.*?)</DataTemplate>')) {
        foreach ($tb in [regex]::Matches($tpl.Groups[1].Value, '(?s)<TextBlock\b.*?/>')) {
            $el = $tb.Value
            if ($el -notmatch 'Foreground\s*=' -and $el -notmatch 'Style\s*=') {
                $bad += (($el -replace '\s+', ' ').Trim())
            }
        }
    }
    return $bad
}

$lintFail = @()
foreach ($f in (Get-ChildItem $PSScriptRoot -Filter '*.ps1')) {
    foreach ($b in (Test-TemplateForegrounds $f.FullName)) {
        $lintFail += "$($f.Name): $b"
    }
}

# ---------------- run ----------------

$fail = @(); $pass = 0
'{0,-9} {1,-34} {2,8}  {3,7}  {4}' -f 'WINDOW', 'ELEMENT', 'RATIO', 'NEEDS', ''
'-' * 78
foreach ($c in $Checks) {
    $kind  = if ($c.K) { $c.K } else { 'text' }
    $ratio = Get-Contrast $c.Fg $c.Bg
    $need  = Get-Required ([double]$c.S) ([bool]$c.B) $kind
    $ok    = $ratio -ge $need
    if ($ok) { $pass++ } else { $fail += [pscustomobject]@{ Where = $c.W; What = $c.T; Ratio = $ratio; Need = $need; Fg = $c.Fg; Bg = $c.Bg } }
    $mark  = if ($kind -eq 'decorative') { 'n/a ' } elseif ($ok) { 'PASS' } else { 'FAIL' }
    $col   = if (-not $ok) { 'Red' } elseif ($kind -eq 'decorative') { 'DarkCyan' } else { 'DarkGray' }
    Write-Host ('{0,-9} {1,-34} {2,7:N2}:1  {3,5:N1}:1  {4}' -f $c.W, $c.T, $ratio, $need, $mark) -ForegroundColor $col
}

''
if ($lintFail.Count -gt 0) {
    Write-Host "Text with no colour of its own (inside a DataTemplate, so the" -ForegroundColor Red
    Write-Host "implicit style will not reach it and it renders default black):" -ForegroundColor Red
    foreach ($l in $lintFail) { Write-Host "  $l" -ForegroundColor Red }
    ''
}
if ($fail.Count -eq 0 -and $lintFail.Count -eq 0) {
    Write-Host "WCAG 2.2 AA: all $pass checks pass, and every templated TextBlock sets its own colour." -ForegroundColor Green
} else {
    Write-Host "WCAG 2.2 AA: $($fail.Count) of $($Checks.Count) contrast FAIL, $($lintFail.Count) uncoloured" -ForegroundColor Red
    foreach ($f in $fail) {
        Write-Host ("  {0}/{1}: {2:N2}:1, needs {3:N1}:1  ({4} on {5})" -f $f.Where, $f.What, $f.Ratio, $f.Need, $f.Fg, $f.Bg) -ForegroundColor Red
    }
    exit 1
}
