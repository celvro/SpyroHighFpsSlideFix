<#
.SYNOPSIS
    Compares every character between two runs of a level replay take: where they part ways, and how fast
    each one gets going from a standstill. A few lines per class, one per character, instead of a log.

.DESCRIPTION
    Reads the actors files the probe writes (lib/actortrace.lua, config REPLAY_ACTORS):
    replay_<take>_ref_actors.csv while the take was recorded, replay_<take>_run<cap>_<stamp>_actors.csv
    during each replay. The reference is the recording when it has one (takes from 2026-11-19 on), else the
    newest 30 FPS run; it is compared with the newest run at another cap, or with every run (-All, one
    column per run). -Reference / -Run pick files.

    Both start their clock when the take starts, so samples are matched by time (the other run
    interpolated at each reference sample), which works across framerates.

    For each character:
      gap      largest 3D distance between the runs, and when it first passed 5 units
      starts   moves from a standstill: horizontal speed rising through 1 after at least 0.1 s below it
      t50/t90  seconds from a start to 50% / 90% of the top speed of that move (its peak in the next 2 s,
               or up to its first change of movement mode, so a ram's leap is not taken for its walk)
      d0.5     distance covered in the first 0.5 s of a move. Coarse: where a move starts is only known to
               the reference's frame, so a 30 FPS reference moves it by up to a frame's distance (two 30 FPS
               runs of one ram, identical to 0.2 units, gave 54.8 and 60.8). Trust t90 for acceleration.
    Per class, the medians of those over every start in each run, and how many characters parted by more
    than 5 units. A slow-accelerating character shows as a longer t90 and a shorter d0.5 in the run at the
    higher framerate.

    Enemies only repeat when the runs see the same thing: a character Spyro touched, hit or scared off is
    only comparable up to that moment, and its gap says when that was.

.EXAMPLE
    tools\Compare-ReplayActors.ps1 -Take LS102_20261116_233040
.EXAMPLE
    tools\Compare-ReplayActors.ps1 -Take LS102_20261116_233040 -Class Ram
#>
param(
    [Parameter(Mandatory)] [string] $Take,
    [string] $Reference,
    [string] $Run,
    [string] $Class,          # only characters whose class contains this text
    [int] $Top = 40,          # characters listed (largest gap first)
    [string] $Out,            # also write the report here (default: build\replay\<take>_actors.txt)
    [switch] $All             # every run of the take against the reference, one column per run
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"
$inv = [Globalization.CultureInfo]::InvariantCulture

function Find-Run([string] $pattern) {
    Get-ChildItem $ProbeDir -Filter "replay_${Take}_run*_actors.csv" | Where-Object { $_.Name -match $pattern } |
        Sort-Object LastWriteTime | Select-Object -Last 1
}
function Resolve-Run([string] $given, [string] $pattern, [string] $what) {
    if ($given) { if (Test-Path $given) { return Get-Item $given }; return Get-Item (Join-Path $ProbeDir $given) }
    $f = Find-Run $pattern
    if (-not $f) { throw "no $what actors file for $Take in $ProbeDir" }
    $f
}
# The reference: the recording itself when it traced the characters (takes from 2026-11-19 on), else the
# newest 30 FPS run.
$recording = Join-Path $ProbeDir "replay_${Take}_ref_actors.csv"
$refFile = if ($Reference) { Resolve-Run $Reference '' '' } elseif (Test-Path $recording) { Get-Item $recording } else { Resolve-Run '' '_run30_' '30 FPS' }
$runFiles = if ($All) {
    @(Get-ChildItem $ProbeDir -Filter "replay_${Take}_run*_actors.csv" | Where-Object { $_.FullName -ne $refFile.FullName } | Sort-Object LastWriteTime)
} else {
    @(Resolve-Run $Run '_run(?!30_)\d+_' 'other-cap')
}
if ($runFiles.Count -eq 0) { throw "no runs of $Take to compare" }

# name -> @{ class; t = List[double]; x; y; z; s (horizontal speed) }
function Load-Actors($file) {
    $actors = @{}
    $fs = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    $reader = New-Object IO.StreamReader($fs)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.StartsWith('# actor,')) {
                $p = $line.Split(',')
                $actors[$p[1]] = @{ class = $p[2]; t = [Collections.Generic.List[double]]::new(); x = [Collections.Generic.List[double]]::new()
                                    y = [Collections.Generic.List[double]]::new(); z = [Collections.Generic.List[double]]::new(); s = [Collections.Generic.List[double]]::new()
                                    m = [Collections.Generic.List[int]]::new() }
                continue
            }
            if ($line.StartsWith('t,') -or $line.Length -eq 0) { continue }
            $c = $line.Split(',')
            $a = $actors[$c[1]]
            if (-not $a) { continue }
            $a.t.Add([double]::Parse($c[0], $inv)); $a.x.Add([double]::Parse($c[2], $inv)); $a.y.Add([double]::Parse($c[3], $inv)); $a.z.Add([double]::Parse($c[4], $inv))
            $vx = [double]::Parse($c[5], $inv); $vy = [double]::Parse($c[6], $inv)
            $a.s.Add([Math]::Sqrt($vx * $vx + $vy * $vy))
            $a.m.Add([int]$c[8])
        }
    } finally { $reader.Close() }
    $actors
}

# Index of the last sample at or before time t (binary search), -1 when t is before the first.
function Find-Index($list, [double] $t) {
    $lo = 0; $hi = $list.Count - 1
    if ($hi -lt 0 -or $t -lt $list[0]) { return -1 }
    while ($lo -lt $hi) { $mid = [int][Math]::Floor(($lo + $hi + 1) / 2); if ($list[$mid] -le $t) { $lo = $mid } else { $hi = $mid - 1 } }
    $lo
}

function Get-Starts($a) {
    $starts = @()
    $n = $a.t.Count
    $stillSince = $null
    for ($i = 1; $i -lt $n; $i++) {
        if ($a.s[$i - 1] -lt 1) { if ($null -eq $stillSince) { $stillSince = $a.t[$i - 1] } } else { $stillSince = $null }
        if ($a.s[$i] -ge 1 -and $a.s[$i - 1] -lt 1 -and $null -ne $stillSince -and ($a.t[$i - 1] - $stillSince) -ge 0.1 - 1e-6) {
            $t0 = $a.t[$i - 1]
            $end = Find-Index $a.t ($t0 + 2)
            # A move ends at a change of movement mode: a ram's walk turns into a leap (Falling, ~457 units/s),
            # whose speed is not the walk's top speed.
            for ($k = $i; $k -le $end; $k++) { if ($a.m[$k] -ne $a.m[$i - 1]) { $end = $k - 1; break } }
            $peak = 0; for ($k = $i; $k -le $end; $k++) { if ($a.s[$k] -gt $peak) { $peak = $a.s[$k] } }
            if ($peak -lt 20) { continue } # a twitch, not a move
            $t50 = $null; $t90 = $null
            for ($k = $i; $k -le $end; $k++) {
                if ($null -eq $t50 -and $a.s[$k] -ge 0.5 * $peak) { $t50 = $a.t[$k] - $t0 }
                if ($a.s[$k] -ge 0.9 * $peak) { $t90 = $a.t[$k] - $t0; break }
            }
            $j = Find-Index $a.t ($t0 + 0.5)
            $d = $null
            if ($j -ge 0 -and $a.t[$j] -ge $t0 + 0.45) {
                $dx = $a.x[$j] - $a.x[$i - 1]; $dy = $a.y[$j] - $a.y[$i - 1]; $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
            }
            $starts += [pscustomobject]@{ t = $t0; peak = $peak; t50 = $t50; t90 = $t90; d05 = $d }
        }
    }
    $starts
}

function Get-Median($values) {
    $v = @($values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    if ($v.Count % 2) { return $v[[int](($v.Count - 1) / 2)] }
    ($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2
}
function Fmt($v, [string] $f = '0.00') { if ($null -eq $v) { '-' } else { ([double]$v).ToString($f, $inv) } }

function Rate($actors) {
    $a = $actors.Values | Where-Object { $_.t.Count -ge 2 } | Select-Object -First 1
    if (-not $a) { return 0 }
    [Math]::Round(($a.t.Count - 1) / ($a.t[$a.t.Count - 1] - $a.t[0]))
}

# One row per character in both: the largest gap, when it passed 5 units, and the starts in each.
function Compare-Pair($refActors, $runActors) {
    $rows = @()
    foreach ($name in $refActors.Keys) {
        $a = $refActors[$name]; $b = $runActors[$name]
        if (-not $b -or $a.t.Count -lt 2 -or $b.t.Count -lt 2) { continue }
        if ($Class -and $a.class -notlike "*$Class*") { continue }
        $max = 0; $maxAt = $null; $first5 = $null
        for ($i = 0; $i -lt $a.t.Count; $i++) {
            $t = $a.t[$i]
            $j = Find-Index $b.t $t
            if ($j -lt 0 -or $j -ge $b.t.Count - 1) { continue }
            $f = ($t - $b.t[$j]) / ($b.t[$j + 1] - $b.t[$j])
            $dx = $a.x[$i] - ($b.x[$j] + ($b.x[$j + 1] - $b.x[$j]) * $f)
            $dy = $a.y[$i] - ($b.y[$j] + ($b.y[$j + 1] - $b.y[$j]) * $f)
            $dz = $a.z[$i] - ($b.z[$j] + ($b.z[$j + 1] - $b.z[$j]) * $f)
            $gap = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)
            if ($gap -gt $max) { $max = $gap; $maxAt = $t }
            if ($null -eq $first5 -and $gap -gt 5) { $first5 = $t }
        }
        $rows += [pscustomobject]@{
            name = $name; class = $a.class; gap = $max; gapAt = $maxAt; first5 = $first5
            startsA = @(Get-Starts $a); startsB = @(Get-Starts $b)
        }
    }
    $rows
}

$refActors = Load-Actors $refFile
$lines = New-Object Collections.Generic.List[string]
$lines.Add("Characters in $Take")
$lines.Add("  reference $($refFile.Name)  (~$(Rate $refActors) FPS)")
$lines.Add("  starts = moves from a standstill; t50/t90 = seconds to 50/90% of that move's top speed; d0.5 = units covered in its first 0.5 s")

if ($All) {
    # Every run against the reference: t90 per class and per character, one column per run.
    $runs = @()
    $k = 0
    foreach ($f in $runFiles) {
        $k++
        $actors = Load-Actors $f
        $fps = Rate $actors
        $runs += [pscustomobject]@{ n = $k; file = $f; fps = $fps; rows = @(Compare-Pair $refActors $actors) }
        $lines.Add("  run $k`: $($f.Name)  (~$fps FPS)")
    }
    $head = ($runs | ForEach-Object { '{0,11}' -f "run $($_.n)" }) -join ''
    $lines.Add('')
    $lines.Add('t90 per class (median over every start; starts in brackets), reference then each run:')
    $lines.Add(('  {0,-30} {1,11}{2}' -f 'class', 'reference', $head))
    $classes = @($runs[0].rows | ForEach-Object class | Sort-Object -Unique)
    foreach ($c in $classes) {
        $refStarts = @($runs[0].rows | Where-Object class -eq $c | ForEach-Object { $_.startsA })
        $cells = foreach ($r in $runs) {
            $s = @($r.rows | Where-Object class -eq $c | ForEach-Object { $_.startsB })
            '{0,11}' -f ("$(Fmt (Get-Median ($s | ForEach-Object t90))) ($($s.Count))")
        }
        $lines.Add(('  {0,-30} {1,11}{2}' -f $c, ("$(Fmt (Get-Median ($refStarts | ForEach-Object t90))) ($($refStarts.Count))"), ($cells -join '')))
    }
    $lines.Add('')
    $lines.Add('t90 per character with a start anywhere (>5 = when it first parted from the reference by 5 units):')
    $lines.Add(('  {0,-34} {1,11}{2}' -f 'name', 'reference', $head))
    foreach ($row in ($runs[0].rows | Sort-Object name)) {
        $any = $row.startsA.Count -gt 0
        $cells = foreach ($r in $runs) {
            $x = $r.rows | Where-Object name -eq $row.name
            if ($x.startsB.Count) { $any = $true }
            '{0,11}' -f ("$(Fmt (Get-Median ($x.startsB | ForEach-Object t90))) >$(Fmt $x.first5 '0.0')")
        }
        if ($any) { $lines.Add(('  {0,-34} {1,11}{2}' -f $row.name, (Fmt (Get-Median ($row.startsA | ForEach-Object t90))), ($cells -join ''))) }
    }
    if (-not $Out) { $dir = Join-Path $BuildDir 'replay'; New-Item -ItemType Directory -Force $dir | Out-Null; $Out = Join-Path $dir "${Take}_actors_all.txt" }
    [IO.File]::WriteAllLines($Out, $lines)
    $lines
    "(written to $Out)"
    return
}

$runFile = $runFiles[0]
$runActors = Load-Actors $runFile
$rows = @(Compare-Pair $refActors $runActors)
$lines.Insert(2, "  compared  $($runFile.Name)  (~$(Rate $runActors) FPS)")
$lines.Add('')
$lines.Add('Per class (medians over every start; reference | compared):')
$lines.Add(('  {0,-30} {1,5} {2,7} {3,13} {4,13} {5,13} {6,15}' -f 'class', 'chars', 'gap>5', 'starts', 't50', 't90', 'd0.5'))
foreach ($g in ($rows | Group-Object class | Sort-Object Name)) {
    $sa = @($g.Group | ForEach-Object { $_.startsA }); $sb = @($g.Group | ForEach-Object { $_.startsB })
    $parted = @($g.Group | Where-Object { $_.gap -gt 5 }).Count
    $lines.Add(('  {0,-30} {1,5} {2,7} {3,13} {4,13} {5,13} {6,15}' -f $g.Name, $g.Count, $parted,
        "$($sa.Count) | $($sb.Count)",
        "$(Fmt (Get-Median ($sa | ForEach-Object t50))) | $(Fmt (Get-Median ($sb | ForEach-Object t50)))",
        "$(Fmt (Get-Median ($sa | ForEach-Object t90))) | $(Fmt (Get-Median ($sb | ForEach-Object t90)))",
        "$(Fmt (Get-Median ($sa | ForEach-Object d05)) '0.0') | $(Fmt (Get-Median ($sb | ForEach-Object d05)) '0.0')"))
}
$lines.Add('')
$lines.Add("Per character, largest gap first (top $Top):")
$lines.Add(('  {0,-34} {1,8} {2,8} {3,8} {4,9} {5,13} {6,15}' -f 'name', 'max gap', 'at', '>5 at', 'starts', 't90', 'd0.5'))
foreach ($r in ($rows | Sort-Object gap -Descending | Select-Object -First $Top)) {
    $lines.Add(('  {0,-34} {1,8} {2,8} {3,8} {4,9} {5,13} {6,15}' -f $r.name, (Fmt $r.gap '0.0'), (Fmt $r.gapAt), (Fmt $r.first5),
        "$($r.startsA.Count)|$($r.startsB.Count)",
        "$(Fmt (Get-Median ($r.startsA | ForEach-Object t90))) | $(Fmt (Get-Median ($r.startsB | ForEach-Object t90)))",
        "$(Fmt (Get-Median ($r.startsA | ForEach-Object d05)) '0.0') | $(Fmt (Get-Median ($r.startsB | ForEach-Object d05)) '0.0')"))
}
$missing = @($refActors.Keys | Where-Object { -not $runActors.ContainsKey($_) }) + @($runActors.Keys | Where-Object { -not $refActors.ContainsKey($_) })
if ($missing.Count) { $lines.Add(''); $lines.Add("In only one run (not compared): $($missing -join ', ')") }

if (-not $Out) { $dir = Join-Path $BuildDir 'replay'; New-Item -ItemType Directory -Force $dir | Out-Null; $Out = Join-Path $dir "${Take}_actors.txt" }
[IO.File]::WriteAllLines($Out, $lines)
$lines
"(written to $Out)"
