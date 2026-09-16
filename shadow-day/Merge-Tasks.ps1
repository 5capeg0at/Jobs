<#
.SYNOPSIS
Unions the pass-2 task JSONs into one catalogue with honest cadence numbers.

.DESCRIPTION
Task ids drift between classifier agents ("jobs-board", "jobs-board-triage", ...). An alias map
(aliases.json: { "alias-id": "canonical-id" }) folds them. Cadence is days-seen divided by the
working days in the study range, where working days exclude weekends, NZ public holidays and the
leave ranges in leave.md, so a "daily" label means daily on days Gerhard actually worked.
Outputs catalogue.json (merged tasks + day index) and catalogue-table.md (sorted table).
#>
[CmdletBinding()]
param(
    [string]$Dir = 'C:\Repos\Personal\jobs\docs\183-shadow-day',
    [string]$Aliases = 'C:\Repos\Personal\jobs\docs\183-shadow-day\tasks\aliases.json',
    [datetime]$From = '2026-05-01',
    [datetime]$To = '2026-09-16'
)
$ErrorActionPreference = 'Stop'

$leave = @()
foreach ($line in Get-Content (Join-Path $Dir 'leave.md')) {
    if ($line -match '^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(\d{4}-\d{2}-\d{2})\s*\|') { $leave += , @([datetime]$Matches[1], [datetime]$Matches[2]) }
}
$holidays = @([datetime]'2026-06-01', [datetime]'2026-07-10')
$workingDays = [System.Collections.Generic.List[string]]::new()
for ($d = $From; $d -le $To; $d = $d.AddDays(1)) {
    if ($d.DayOfWeek -in 'Saturday', 'Sunday') { continue }
    if ($holidays -contains $d) { continue }
    if ($leave | Where-Object { $d -ge $_[0] -and $d -le $_[1] }) { continue }
    $workingDays.Add($d.ToString('yyyy-MM-dd'))
}
$workingSet = [System.Collections.Generic.HashSet[string]]::new($workingDays)

$alias = @{}
if (Test-Path $Aliases) { (Get-Content $Aliases -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $alias[$_.Name] = $_.Value } }
function Canon($id) { $seen = @{}; while ($alias.ContainsKey($id) -and -not $seen[$id]) { $seen[$id] = 1; $id = $alias[$id] }; $id }

$files = Get-ChildItem (Join-Path $Dir 'tasks') -Filter '*-p2.json'
if (-not $files) { throw 'no *-p2.json yet' }
$tasks = @{}; $days = @{}
foreach ($f in $files) {
    $p = Get-Content $f.FullName -Raw | ConvertFrom-Json
    foreach ($day in $p.days) {
        $day | Add-Member -NotePropertyName tasks_canon -NotePropertyValue @($day.tasks | ForEach-Object { Canon $_ } | Sort-Object -Unique) -Force
        $days[$day.date] = $day
    }
    foreach ($t in $p.tasks) {
        $id = Canon $t.id
        if (-not $tasks.ContainsKey($id)) {
            $tasks[$id] = [ordered]@{ id = $id; names = @(); categories = @(); triggers = @(); inputs = @(); connectors = @(); outputs = @(); writes = @(); judgement = @(); dates = @(); sessions = @(); examples = @(); hints = @(); source_ids = @(); periods = @() }
        }
        $m = $tasks[$id]
        $m.names += $t.name; $m.categories += $t.category; $m.triggers += $t.trigger
        $m.inputs += @($t.inputs); $m.connectors += @($t.connectors); $m.outputs += $t.output
        $m.writes += $t.writes; $m.judgement += $t.judgement
        $m.dates += @($t.dates); $m.sessions += @($t.sessions)
        if ($t.example) { $m.examples += $t.example }; if ($t.automation_hint) { $m.hints += $t.automation_hint }
        $m.source_ids += $t.id; $m.periods += $p.period
    }
}

$writeRank = @{ none = 0; 'local-file' = 1; 'jobs-board' = 2; 'repo-commit' = 3; ado = 4; slack = 5; email = 6; confluence = 6; 'local-env' = 3; deploy = 9 }
$judgeRank = @{ low = 0; medium = 1; high = 2 }
$out = foreach ($m in $tasks.Values) {
    $dates = @($m.dates | Sort-Object -Unique)
    $work = @($dates | Where-Object { $workingSet.Contains($_) })
    $freq = if ($workingDays.Count) { [math]::Round($work.Count / $workingDays.Count, 2) } else { 0 }
    $months = @($dates | ForEach-Object { $_.Substring(0, 7) } | Sort-Object -Unique)
    $cadence = if ($freq -ge 0.6) { 'daily' } elseif ($freq -ge 0.2) { 'weekly-ish' } elseif ($months.Count -ge 3) { 'recurring' } elseif ($work.Count -ge 2) { 'occasional' } else { 'one-off' }
    [pscustomobject]@{
        id = $m.id
        name = ($m.names | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        category = ($m.categories | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        trigger = ($m.triggers | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        cadence = $cadence
        working_days_seen = $work.Count
        share_of_working_days = $freq
        months = $months -join ','
        writes = ($m.writes | Where-Object { $_ } | Sort-Object { $writeRank[$_] } -Descending | Select-Object -First 1)
        judgement = ($m.judgement | Where-Object { $_ } | Sort-Object { $judgeRank[$_] } -Descending | Select-Object -First 1)
        inputs = (@($m.inputs | Where-Object { $_ } | Sort-Object -Unique) -join ',')
        connectors = (@($m.connectors | Where-Object { $_ } | Sort-Object -Unique) -join ',')
        dates = $dates
        examples = @($m.examples | Select-Object -Unique -First 3)
        hints = @($m.hints | Select-Object -Unique)
        source_ids = @($m.source_ids | Sort-Object -Unique)
    }
}
$out = $out | Sort-Object working_days_seen -Descending

$result = [ordered]@{
    range = "$($From.ToString('yyyy-MM-dd'))..$($To.ToString('yyyy-MM-dd'))"
    working_days = $workingDays.Count
    tasks = $out
    days = ($days.Values | Sort-Object date)
}
$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Dir 'catalogue.json') -Encoding utf8

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("| id | name | cadence | days | share | months | writes | judgement | shadow-safe |")
[void]$sb.AppendLine("|---|---|---|---|---|---|---|---|---|")
foreach ($t in $out) {
    $safe = if ($t.writes -in 'none', 'local-file' -and $t.judgement -ne 'high') { 'yes' } elseif ($t.writes -in 'none', 'local-file') { 'report-only' } else { 'no' }
    [void]$sb.AppendLine("| $($t.id) | $($t.name) | $($t.cadence) | $($t.working_days_seen) | $($t.share_of_working_days) | $($t.months) | $($t.writes) | $($t.judgement) | $safe |")
}
$sb.ToString() | Set-Content (Join-Path $Dir 'catalogue-table.md') -Encoding utf8
Write-Host "[OK] $($out.Count) tasks over $($workingDays.Count) working days -> catalogue.json, catalogue-table.md"
