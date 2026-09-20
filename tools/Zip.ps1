# Shared zip writer for the release packagers. Dot-source this file: . "$PSScriptRoot\Zip.ps1"

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

<#
.SYNOPSIS
    Writes a zip from an ordered map of entry name -> content.

.DESCRIPTION
    Each value is either a path to an existing file (copied in), a string of literal text
    (written as UTF-8 without a BOM), or $null for an empty entry. Entry names use forward
    slashes: Compress-Archive in Windows PowerShell writes backslash paths, which some
    extractors and mod managers treat as file names instead of folders.
#>
function New-ZipFromEntries {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Entries
    )

    if (Test-Path $Path) { Remove-Item $Path -Force }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null

    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $Entries.Keys) {
            $source = $Entries[$name]
            # Literal text can hold newlines and other characters Test-Path rejects outright, so only
            # single-line values are even tried as paths, and a failing test means "this is text".
            $isFile = $false
            if ($source -and $source -notmatch '[\r\n]') {
                try { $isFile = Test-Path -LiteralPath $source -PathType Leaf } catch { $isFile = $false }
            }
            if ($isFile) {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $source, $name, 'Optimal') | Out-Null
            } else {
                $entry = $zip.CreateEntry($name)
                if ($source) {
                    $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
                    try { $writer.Write($source) } finally { $writer.Dispose() }
                }
            }
        }
    } finally {
        $zip.Dispose()
    }

    Write-Host "Built $Path"
    $check = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try { $check.Entries | ForEach-Object { Write-Host "  $($_.FullName) ($($_.Length) bytes)" } } finally { $check.Dispose() }
}
