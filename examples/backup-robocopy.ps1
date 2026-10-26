# Example backup for /wrap on Windows: robocopy mirror per target + per-target verification + JSON status.
#
# Usage:
#   $env:BACKUP_PAIRS  = 'C:\work\project=>E:\Backup\project;C:\work\notes=>E:\Backup\notes'
#   $env:BACKUP_STATUS = '.claude\backup-status.json'
#   pwsh -File examples/backup-robocopy.ps1 [-AcceptPrune]
#
# Behaviour:
#   - One run at a time (named mutex). A second run prints "SKIP - another backup run is in progress" and exits 0.
#   - /MIR mirror, but a /L dry run first: if more than $MaxPrune files would be deleted on a target, that target
#     is ABORTED (source may be unmounted or damaged). Re-run with -AcceptPrune only on purpose.
#   - robocopy exit codes 0-7 are success, 8+ are failure.
#   - After copying, each target is verified: the newest 5 source files must exist on the target with the same
#     size, and the target's newest file must not be older than the source's newest file minus
#     $MtimeToleranceSec (default 120; robocopy keeps source mtimes). The status file records the newest file,
#     its mtime and size, the source's newest mtime and the file count per target.
#   - node_modules, .venv, __pycache__, dist, build and *.tmp are never copied or checked.
#   - Each source folder name must be unique: it is the target's key in the status file.
#   - The status file is written atomically (tmp + Move-Item).
#   - Exit code 0 only if every target passed.

param(
    [switch]$AcceptPrune,
    [int]$MaxPrune = 500,
    [int]$MtimeToleranceSec = 120
)

$ErrorActionPreference = 'Stop'

$pairs = $env:BACKUP_PAIRS
if (-not $pairs) { [Console]::Error.WriteLine("Set BACKUP_PAIRS to 'source=>target;source=>target'"); exit 2 }
$statusPath = if ($env:BACKUP_STATUS) { $env:BACKUP_STATUS } else { '.claude\backup-status.json' }
$excludeDirs = @('node_modules', '.venv', '__pycache__', 'dist', 'build')
$pairList = @($pairs -split ';' | Where-Object { $_ })

# Targets are keyed by the source folder name, so two sources with the same name would overwrite each other.
$seen = @{}
foreach ($pair in $pairList) {
    $leaf = Split-Path (($pair -split '=>', 2)[0]) -Leaf
    if ($seen.ContainsKey($leaf)) {
        [Console]::Error.WriteLine("ERROR - two sources share the folder name '$leaf'; rename one so each status entry is unique")
        exit 2
    }
    $seen[$leaf] = $true
}

$lock = New-Object System.Threading.Mutex($false, 'Global\claude-wrap-backup')
try { $haveLock = $lock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) { Write-Host 'SKIP - another backup run is in progress'; exit 0 }

$targets = [ordered]@{}
$allOk = $true

try {
    foreach ($pair in $pairList) {
        $src, $dst = $pair -split '=>', 2
        $name = Split-Path $src -Leaf
        $entry = [ordered]@{ ok = $false; rc = -1; detail = ''; newestFile = ''; newestMtime = ''; newestSize = 0; sourceNewestMtime = ''; fileCount = 0 }

        if (-not (Test-Path $src -PathType Container)) {
            $entry.detail = 'skipped - source missing'
        } else {
            New-Item -ItemType Directory -Force -Path $dst | Out-Null

            # Guard: count what /MIR would delete (robocopy /L lists "*EXTRA File" lines) before deleting anything.
            $dry = robocopy $src $dst /MIR /L /NJH /NJS /NP /NDL /XD @excludeDirs /XF *.tmp /R:0 /W:0
            $prune = @($dry | Select-String '\*EXTRA File').Count

            if ($prune -gt $MaxPrune -and -not $AcceptPrune) {
                $entry.detail = "ABORTED - mirror would delete $prune files (> $MaxPrune); check the source, then use -AcceptPrune"
            } else {
                robocopy $src $dst /MIR /FFT /R:2 /W:5 /NJH /NP /NDL /NFL /XD @excludeDirs /XF *.tmp | Out-Null
                $rc = $LASTEXITCODE
                $entry.rc = $rc
                if ($rc -ge 8) {
                    $entry.detail = "robocopy error rc=$rc"
                } else {
                    # Verify: newest 5 source files must be on the target with identical size.
                    $srcRoot = (Resolve-Path $src).Path.TrimEnd('\')
                    $fails = 0; $checked = 0
                    # Match the excluded folder names on the path below the source root only.
                    $top = @(Get-ChildItem $srcRoot -Recurse -File -Force |
                        Where-Object { $_.FullName.Substring($srcRoot.Length) -notmatch '\\(node_modules|\.git|\.venv|__pycache__|dist|build)\\' -and $_.Extension -ne '.tmp' } |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 5)
                    foreach ($f in $top) {
                        $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
                        $t = Join-Path $dst $rel; $checked++
                        if (-not (Test-Path $t) -or (Get-Item $t -Force).Length -ne $f.Length) {
                            $fails++; Write-Host "VERIFY FAIL [$name] $rel"
                        }
                    }

                    $dstFiles = Get-ChildItem $dst -Recurse -File -Force
                    $newest = $dstFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($newest) {
                        $dstRoot = (Resolve-Path $dst).Path.TrimEnd('\')
                        $entry.newestFile = $newest.FullName.Substring($dstRoot.Length).TrimStart('\')
                        $entry.newestMtime = $newest.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        $entry.newestSize = $newest.Length
                    }
                    $entry.fileCount = @($dstFiles).Count

                    # Freshness: the target's newest file must not be older than the source's newest, minus the tolerance.
                    $lag = 0
                    if ($top.Count -gt 0) {
                        $entry.sourceNewestMtime = $top[0].LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        if ($newest) { $lag = [int]($top[0].LastWriteTimeUtc - $newest.LastWriteTimeUtc).TotalSeconds }
                    }

                    if ($fails -ne 0 -or $checked -eq 0 -or $entry.newestSize -le 0) {
                        $entry.detail = "verify failed - $fails of $checked spot checks missing or wrong size"
                    } elseif ($lag -gt $MtimeToleranceSec) {
                        $entry.detail = "verify failed - target newest file is ${lag}s older than source newest (tolerance ${MtimeToleranceSec}s)"
                    } else {
                        $entry.ok = $true
                        $entry.detail = "mirror rc=$rc, $checked/$checked spot checks OK"
                    }
                }
            }
        }

        if (-not $entry.ok) { $allOk = $false }
        Write-Host ("{0,-5} {1}: {2}" -f $(if ($entry.ok) { 'OK' } else { 'FAIL' }), $name, $entry.detail)
        $targets[$name] = $entry
    }

    # Build the whole status document first, then write it atomically.
    $json = [ordered]@{ lastRun = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); targets = $targets } |
        ConvertTo-Json -Depth 5
    $dir = Split-Path $statusPath -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json | Out-File -Encoding utf8 "$statusPath.tmp"
    Move-Item -Force "$statusPath.tmp" $statusPath
    Write-Host "status: $statusPath ($((Get-Item $statusPath).Length) bytes)"
}
finally {
    $lock.ReleaseMutex()
}

if ($allOk) { exit 0 } else { exit 1 }
