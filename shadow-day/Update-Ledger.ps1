<#
.SYNOPSIS
Appends one shadow-day run, and for a compare its per-task verdicts and questions, to ledger.json.

.DESCRIPTION
The ledger is the machine-readable side of the shadow folder: the day files stay prose for Gerhard,
this file feeds the pane and the streak grid. Everything here is parsed by regex from the day file,
so the prompts carry the contract (Compare table columns, numbered questions). Re-running for the
same date and mode replaces that day's rows rather than duplicating them.

.EXAMPLE
Update-Ledger.ps1 -Date 2026-09-11 -Mode evening -StartedAt $t0 -Ok $true -Chars 13751 -SlackTs 1758000000.123 -SlackChannel D0.. -SlackPermalink https://...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][datetime]$Date,
    [Parameter(Mandatory)][ValidateSet('morning', 'evening')][string]$Mode,
    [datetime]$StartedAt = (Get-Date),
    [bool]$Ok = $true,
    [int]$Chars = 0,
    [string]$SlackTs = '',
    [string]$SlackChannel = '',
    [string]$SlackPermalink = '',
    [string]$Dir = 'C:\Repos\Personal\jobs\docs\183-shadow-day'
)
$ErrorActionPreference = 'Stop'
$d = $Date.ToString('yyyy-MM-dd')
$path = Join-Path $Dir 'ledger.json'
$ledger = if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { [pscustomobject]@{ runs = @(); tasks = @(); questions = @() } }
foreach ($k in 'runs', 'tasks', 'questions') { if (-not $ledger.PSObject.Properties[$k]) { $ledger | Add-Member $k @() } }

$runs = @($ledger.runs | Where-Object { -not ($_.date -eq $d -and $_.mode -eq $Mode) })
$runs += [pscustomobject]@{
    date = $d; mode = $Mode; startedAt = $StartedAt.ToString('s'); finishedAt = (Get-Date).ToString('s')
    ok = $Ok; chars = $Chars; slackTs = $SlackTs; slackChannel = $SlackChannel; slackPermalink = $SlackPermalink
}
$ledger.runs = $runs

if ($Mode -eq 'evening') {
    $text = Get-Content (Join-Path $Dir "shadow\$d.md") -Raw
    $tasks = @($ledger.tasks | Where-Object { $_.date -ne $d })
    $compare = [regex]::Match($text, '(?ms)^## Compare\s*$(.*?)(?=^## |\z)').Groups[1].Value
    foreach ($line in ($compare -split "`n")) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = ($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() }
        if ($cells.Count -lt 4 -or $cells[0] -in 'task', '' -or $cells[0] -match '^-+$') { continue }
        $tasks += [pscustomobject]@{
            date = $d; task = $cells[0]; plan = $cells[1]; actual = $cells[2]
            verdict = ($cells[3] -replace '[^a-z-]', ''); note = $(if ($cells.Count -ge 5) { $cells[4] } else { '' })
        }
    }
    $ledger.tasks = $tasks
    $questions = @($ledger.questions | Where-Object { $_.date -ne $d })
    $qs = [regex]::Match($text, '(?ms)^## Questions for Gerhard\s*$(.*?)(?=^## |\z)').Groups[1].Value
    foreach ($m in [regex]::Matches($qs, '(?m)^\s*(\d+)[.)]\s+(.+)$')) {
        $questions += [pscustomobject]@{ date = $d; n = [int]$m.Groups[1].Value; text = $m.Groups[2].Value.Trim() }
    }
    $ledger.questions = $questions
}

$ledger | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8
"[OK] ledger: $($ledger.runs.Count) runs, $($ledger.tasks.Count) task rows, $($ledger.questions.Count) questions"
