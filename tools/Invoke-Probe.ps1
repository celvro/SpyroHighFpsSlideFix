<#
.SYNOPSIS
    Sends a command to the running probe (cmd.txt) and waits for its answer (cmd_result.txt).

.DESCRIPTION
    The probe (ue4ss/DevMods/SpyroFpsProbe, lib/cmd.lua) takes cmd.txt from its mod folder every few
    frames, runs each line and appends "<id> TAB <status> TAB <text>" lines to cmd_result.txt. This
    script writes one command with a fresh id (without a BOM, and atomically: a temp file moved into
    place, waiting for the previous cmd.txt to be taken first) and prints the answer.

    Statuses: ok (finished), started (runs over frames; done or error follows), done, error. By default
    the script waits through "started" for the final answer; -Async returns at "started".

    Exit code: 0 ok/done, 1 error, 2 no answer within -Timeout (is the game running with the probe?).

    `help` lists the commands. The useful ones: ping, state, cap FPS, key NAME, keys, travel LSnnn,
    swap 1|2|3, reload, teleport X Y Z [yaw=DEG] [rel], quicksave save|load, replay [take=ID] [cap=FPS],
    replay-reset, replay-abort, replay-record start|stop, takes [LSnnn], trigger TOOL [options],
    unlock, eval LUA. (Never write a hash sign followed by a closing angle bracket in this help block:
    that pair ends the comment.)

.PARAMETER Command
    The command line, e.g. "cap 320" or "replay take=LS102_20261116_230304 cap=320". Several words
    without quotes work too: .\tools\Invoke-Probe.ps1 cap 320

.PARAMETER Timeout
    Seconds to wait for the final answer (default 30; a replay or travel needs more, e.g. -Timeout 600).

.PARAMETER Async
    Return at "started" instead of waiting for done/error.

.PARAMETER Quiet
    Print only the answer's text, not "<status>: ".

.EXAMPLE
    .\tools\Invoke-Probe.ps1 state

.EXAMPLE
    .\tools\Invoke-Probe.ps1 replay take=LS102_20261116_230304 cap=320 -Timeout 900

.EXAMPLE
    .\tools\Invoke-Probe.ps1 'eval pawn.CharacterMovement.MaxWalkSpeed'
#>
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
    [string[]] $Command,
    [double] $Timeout = 30,
    [switch] $Async,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if (-not (Test-Path $ProbeDir)) { throw "Probe not deployed: $ProbeDir (run tools\Install-UE4SS.ps1 -Probe)" }
$cmdFile = Join-Path $ProbeDir 'cmd.txt'
$resultFile = Join-Path $ProbeDir 'cmd_result.txt'

$line = ($Command -join ' ').Trim()
if (-not $line) { throw 'No command given (try: help)' }
$id = 'p{0}{1:x4}' -f (Get-Date -Format 'HHmmssfff'), (Get-Random -Maximum 65536)
$deadline = (Get-Date).AddSeconds($Timeout)
$noBom = [Text.UTF8Encoding]::new($false)

# Written to a temp file and moved into place, so the probe never reads half a file. Move-Item fails
# while an earlier cmd.txt is still waiting to be taken (or another writer got there first): retry.
$tmp = Join-Path $ProbeDir ("cmd_{0}.tmp" -f $id)
[IO.File]::WriteAllText($tmp, "@$id $line`n", $noBom)
$sent = $false
while (-not $sent) {
    try {
        Move-Item -LiteralPath $tmp -Destination $cmdFile -ErrorAction Stop
        $sent = $true
    } catch {
        if ((Get-Date) -gt $deadline) {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            Write-Error "cmd.txt was never taken: is the game running with the probe loaded? ($cmdFile)" -ErrorAction Continue
            exit 2
        }
        Start-Sleep -Milliseconds 50
    }
}

# Read the result file shared (the probe appends to it while we read) and pick out our id's lines.
function Read-Results {
    if (-not (Test-Path -LiteralPath $resultFile)) { return @() }
    try {
        $fs = [IO.File]::Open($resultFile, 'Open', 'Read', 'ReadWrite')
        try { $text = ([IO.StreamReader]::new($fs, $noBom)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return @() }
    $prefix = "$id`t"
    return @($text -split "`r?`n" | Where-Object { $_.StartsWith($prefix) } | ForEach-Object {
        $parts = $_.Split("`t", 3)
        [pscustomobject]@{ Status = $parts[1]; Text = ($parts[2] -replace '\\n', "`n") }
    })
}

$shown = 0
while ($true) {
    # @() matters: a function returning one object unrolls it, and a lone [pscustomobject] has no
    # .Count in Windows PowerShell 5.1, so a single answer would never be seen.
    $results = @(Read-Results)
    for ($i = $shown; $i -lt $results.Count; $i++) {
        $r = $results[$i]
        if ($Quiet) { Write-Output $r.Text } else { Write-Output ("{0}: {1}" -f $r.Status, $r.Text) }
        switch ($r.Status) {
            'ok' { exit 0 }
            'done' { exit 0 }
            'error' { exit 1 }
            'started' { if ($Async) { exit 0 } }
        }
    }
    $shown = $results.Count
    if ((Get-Date) -gt $deadline) {
        $taken = -not (Test-Path -LiteralPath $cmdFile)
        $why = if ($taken -and $shown -gt 0) { 'still running' } elseif ($taken) { 'taken, no answer yet' } else { 'not taken yet' }
        Write-Error "No final answer for '$line' within $Timeout s ($why). Results: $resultFile" -ErrorAction Continue
        exit 2
    }
    Start-Sleep -Milliseconds 100
}
