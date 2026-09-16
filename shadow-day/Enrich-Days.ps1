<#
.SYNOPSIS
Writes one enrichment file per calendar day (Pacific/Auckland) recording what the structured
systems saw Gerhard do: ADO work item field changes and comments, commits in Kupe/Bridge/Jobs,
build and release runs he requested (with the colour stages a Release run actually deployed),
and pull requests he created, completed or voted on.

.DESCRIPTION
Read-only against ADO (bearer token from `az account get-access-token`) and local git. Output
goes to enrich\YYYY-MM-DD.md next to the transcript day-files, so a classifier can read the
two side by side. Work item history comes from the reporting revisions stream (one paginated
pull for the whole range) rather than per-day WIQL, because WIQL's ChangedBy only sees the
latest change on an item.
#>
[CmdletBinding()]
param(
    [datetime]$From = '2026-05-01',
    [datetime]$To = (Get-Date).Date.AddDays(1),
    [string]$OutDir = 'C:\Repos\Personal\jobs\docs\183-shadow-day\enrich',
    [string]$Me = 'Gerhard Wissing',
    [switch]$SkipPrVotes
)

$ErrorActionPreference = 'Stop'
$org = 'https://dev.azure.com/FINNZ'; $project = 'FishServe'
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('New Zealand Standard Time')
# ConvertTimeToUtc(x, $tz) refuses a Local-kind value; treat both bounds as NZ wall-clock.
$From = [datetime]::SpecifyKind($From, 'Unspecified'); $To = [datetime]::SpecifyKind($To, 'Unspecified')
New-Item -ItemType Directory -Force $OutDir | Out-Null

$token = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
if (-not $token) { throw 'No ADO token; run az login' }
$headers = @{ Authorization = "Bearer $token" }

function Get-Ado($url) { Invoke-RestMethod -Uri $url -Headers $headers -Method Get }
# Invoke-RestMethod hands back DateTime objects (already shifted to this machine's zone) for ISO strings; raw strings are UTC.
function ToLocal($v) {
    if ($v -is [datetime]) {
        if ($v.Kind -eq 'Utc') { return [System.TimeZoneInfo]::ConvertTimeFromUtc($v, $tz) }
        return [System.TimeZoneInfo]::ConvertTime($v, $tz)
    }
    [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::Parse("$v", $null, 'AdjustToUniversal'), $tz)
}
function DayKey([datetime]$local) { $local.ToString('yyyy-MM-dd') }
$fromUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($From, $tz).ToString('o')
$toUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($To, $tz).ToString('o')

# day -> section -> List[string]
$days = @{}
function Add-Line([datetime]$local, [string]$section, [string]$line) {
    if ($local -lt $From -or $local -ge $To) { return }
    $k = DayKey $local
    if (-not $days.ContainsKey($k)) { $days[$k] = [ordered]@{} }
    if (-not $days[$k].Contains($section)) { $days[$k][$section] = [System.Collections.Generic.List[string]]::new() }
    $days[$k][$section].Add("- $($local.ToString('HH:mm')) $line")
}

# ---------------------------------------------------------------- work items
Write-Host '[..] work item revisions'
$fields = 'System.Id,System.Title,System.WorkItemType,System.State,System.ChangedBy,System.ChangedDate,System.AssignedTo,System.IterationPath,Microsoft.VSTS.Scheduling.StoryPoints,System.Tags'
$url = "$org/$project/_apis/wit/reporting/workitemrevisions?startDateTime=$fromUtc&fields=$fields&api-version=7.1"
$revs = [System.Collections.Generic.List[object]]::new()
do {
    $page = Get-Ado $url
    foreach ($v in $page.values) { $revs.Add($v) }
    $url = $page.nextLink
} while (-not $page.isLastBatch -and $url)
Write-Host "[..] $($revs.Count) revisions across all users"

$byItem = $revs | Group-Object { $_.id }
$touchedItems = @{}
foreach ($g in $byItem) {
    $ordered = $g.Group | Sort-Object rev
    $prev = $null
    foreach ($r in $ordered) {
        $f = $r.fields
        $who = if ($f.'System.ChangedBy'.displayName) { $f.'System.ChangedBy'.displayName } else { "$($f.'System.ChangedBy')" }
        if ($who -like "$Me*") {
            $touchedItems[$r.id] = $f.'System.Title'
            $delta = if ($null -eq $prev) { 'created' } else {
                $changes = foreach ($name in 'System.State', 'System.AssignedTo', 'System.IterationPath', 'Microsoft.VSTS.Scheduling.StoryPoints', 'System.Tags', 'System.Title') {
                    $a = $prev.fields.$name; $b = $f.$name
                    if ($a -is [pscustomobject]) { $a = $a.displayName }; if ($b -is [pscustomobject]) { $b = $b.displayName }
                    if ("$a" -ne "$b") { "$($name.Split('.')[-1]) $a -> $b" }
                }
                if ($changes) { $changes -join '; ' } else { 'edited (description/other)' }
            }
            Add-Line (ToLocal $f.'System.ChangedDate') 'ADO work items' "#$($r.id) [$($f.'System.WorkItemType')] $($f.'System.Title'): $delta"
        }
        $prev = $r
    }
}
Write-Host "[..] $($touchedItems.Count) items touched by $Me; fetching comments"
foreach ($id in $touchedItems.Keys) {
    try {
        $c = Get-Ado "$org/$project/_apis/wit/workItems/$id/comments?api-version=7.1-preview.3"
        foreach ($cm in $c.comments) {
            if ($cm.createdBy.displayName -notlike "$Me*") { continue }
            $text = ($cm.text -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
            if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }
            Add-Line (ToLocal $cm.createdDate) 'ADO comments' "#$id $($touchedItems[$id]): $text"
        }
    } catch { Write-Host "[FAIL] comments $id : $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- builds + release stages
Write-Host '[..] builds'
$cursor = $From
while ($cursor -lt $To) {
    $end = [datetime]::new([Math]::Min($cursor.AddDays(14).Ticks, $To.Ticks))
    $b = Get-Ado "$org/$project/_apis/build/builds?minTime=$([System.TimeZoneInfo]::ConvertTimeToUtc($cursor,$tz).ToString('o'))&maxTime=$([System.TimeZoneInfo]::ConvertTimeToUtc($end,$tz).ToString('o'))&definitions=56,57,64&`$top=1000&api-version=7.1"
    foreach ($run in $b.value) {
        $mine = $run.requestedFor.displayName -like "$Me*"
        $branch = $run.sourceBranch -replace '^refs/heads/', ''
        $when = if ($run.finishTime) { $run.finishTime } else { $run.queueTime }
        $stages = ''
        if ($run.definition.id -eq 64) {
            try {
                $tl = Get-Ado "$org/$project/_apis/build/builds/$($run.id)/timeline?api-version=7.1"
                $stages = ($tl.records | Where-Object { $_.type -eq 'Stage' -and $_.name -like 'Deploy*' -and $_.result -in 'succeeded', 'failed', 'partiallySucceeded' } | ForEach-Object { "$(($_.name -replace '^Deploy','').Trim())=$($_.result)" }) -join ','
                if ($stages) { $stages = " stages[$stages]" }
            } catch { $stages = ' stages[timeline failed]' }
        }
        $tag = if ($mine) { 'MINE' } else { $run.requestedFor.displayName }
        Add-Line (ToLocal $when) 'Pipelines' "$($run.definition.name) #$($run.buildNumber) $branch $($run.result) by $tag$stages"
    }
    $cursor = $end
}

Write-Host '[..] classic releases'
try {
    $rel = Get-Ado "https://vsrm.dev.azure.com/FINNZ/$project/_apis/release/releases?minCreatedTime=$fromUtc&maxCreatedTime=$toUtc&`$expand=environments&`$top=200&api-version=7.1"
    foreach ($r in $rel.value) {
        $envs = ($r.environments | Where-Object { $_.status -ne 'notStarted' } | ForEach-Object { "$($_.name)=$($_.status)" }) -join ','
        $tag = if ($r.createdBy.displayName -like "$Me*") { 'MINE' } else { $r.createdBy.displayName }
        Add-Line (ToLocal $r.createdOn) 'Pipelines' "Release $($r.name) ($($r.releaseDefinition.name)) by $tag envs[$envs]"
    }
} catch { Write-Host "[FAIL] releases: $($_.Exception.Message)" }

# ---------------------------------------------------------------- pull requests
Write-Host '[..] pull requests'
$prUrl = "$org/$project/_apis/git/repositories/Kupe/pullrequests?searchCriteria.status=all&searchCriteria.minTime=$([System.TimeZoneInfo]::ConvertTimeToUtc($From.AddDays(-60),$tz).ToString('o'))&searchCriteria.maxTime=$toUtc&`$top=500&api-version=7.1"
$prs = (Get-Ado $prUrl).value
$myId = ($prs | Where-Object { $_.createdBy.displayName -like "$Me*" } | Select-Object -First 1).createdBy.id
foreach ($pr in $prs) {
    $mine = $pr.createdBy.displayName -like "$Me*"
    if ($mine) {
        Add-Line (ToLocal $pr.creationDate) 'Pull requests' "created PR $($pr.pullRequestId): $($pr.title)"
        if ($pr.closedDate) { Add-Line (ToLocal $pr.closedDate) 'Pull requests' "PR $($pr.pullRequestId) $($pr.status): $($pr.title)" }
    }
    $reviewer = $pr.reviewers | Where-Object { $_.id -eq $myId }
    if (-not $SkipPrVotes -and $reviewer -and -not $mine) {
        try {
            $threads = Get-Ado "$org/$project/_apis/git/repositories/Kupe/pullRequests/$($pr.pullRequestId)/threads?api-version=7.1"
            foreach ($t in $threads.value) {
                foreach ($c in $t.comments) {
                    if ($c.author.displayName -notlike "$Me*") { continue }
                    $text = "$($c.content)".Trim(); if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
                    $kind = if ($c.commentType -eq 'system') { 'vote/system' } else { 'review comment' }
                    Add-Line (ToLocal $c.publishedDate) 'Pull requests' "PR $($pr.pullRequestId) ($($pr.createdBy.displayName)) $kind : $text"
                }
            }
        } catch { Write-Host "[FAIL] threads PR $($pr.pullRequestId): $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- git
Write-Host '[..] git'
$repos = @(
    @{ path = 'C:\Repos\Kupe'; author = 'Gerhard Wissing' },
    @{ path = 'C:\Repos\Bridge'; author = 'Gerhard Wissing' },
    @{ path = 'C:\Repos\Personal\jobs'; author = '5capeg0at|Gerhard Wissing' }
)
foreach ($r in $repos) {
    $name = Split-Path $r.path -Leaf
    $lines = git -C $r.path log --all --author="$($r.author)" --perl-regexp --since=$($From.ToString('yyyy-MM-dd')) --until=$($To.ToString('yyyy-MM-dd')) --format='%aI|%h|%D|%s'
    foreach ($l in $lines) {
        $p = $l -split '\|', 4
        $local = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::Parse($p[0]), $tz).DateTime
        $refs = if ($p[2]) { " {$($p[2] -replace 'origin/','' -replace 'HEAD -> ','')}" } else { '' }
        Add-Line $local 'Git commits' "[$name] $($p[1]) $($p[3])$refs"
    }
}

# ---------------------------------------------------------------- write
Get-ChildItem $OutDir -Filter '*.md' | Remove-Item
foreach ($k in ($days.Keys | Sort-Object)) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $k ($(([datetime]$k).DayOfWeek)) - system record")
    [void]$sb.AppendLine()
    foreach ($section in 'ADO work items', 'ADO comments', 'Pull requests', 'Git commits', 'Pipelines') {
        if (-not $days[$k].Contains($section)) { continue }
        [void]$sb.AppendLine("## $section")
        foreach ($line in ($days[$k][$section] | Sort-Object)) { [void]$sb.AppendLine($line) }
        [void]$sb.AppendLine()
    }
    [System.IO.File]::WriteAllText((Join-Path $OutDir "$k.md"), $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}
Write-Host "[OK] $($days.Count) enrichment files -> $OutDir"
