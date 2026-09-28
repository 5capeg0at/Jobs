<#
.SYNOPSIS
Writes a markdown snapshot of the ADO work Gerhard has open right now: items assigned to him that
aren't Done/Removed/Closed, with each task's parent PBI.

.DESCRIPTION
Enrich-Days.ps1 records what changed; this records what's on his plate. Without it, sprint work
nobody touched since the last working day is invisible to the morning plan, however large. Read-only
(bearer token from `az account get-access-token`).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutFile,
    # UTC instant to read the board as of, so a dry run against a past day can't see later assignments.
    [datetime]$AsOfUtc = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
$org = 'https://dev.azure.com/FINNZ'; $project = 'FishServe'
$token = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
if (-not $token) { throw 'No ADO token; run az login' }
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

$asOf = $AsOfUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
# The 60-day ChangedDate floor drops items abandoned long ago but still assigned.
$floor = $AsOfUtc.AddDays(-60).ToString('yyyy-MM-dd')
$wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$project' AND [System.AssignedTo] = @Me AND [System.State] NOT IN ('Done', 'Removed', 'Closed') AND [System.ChangedDate] >= '$floor' ORDER BY [System.ChangedDate] DESC ASOF '$asOf'" } | ConvertTo-Json
$ids = (Invoke-RestMethod -Method Post -Uri "$org/$project/_apis/wit/wiql?api-version=7.1" -Headers $headers -Body $wiql).workItems.id

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Open ADO work assigned to Gerhard (as of $asOf)")
[void]$sb.AppendLine()
if (-not $ids) { [void]$sb.AppendLine('(none)'); $sb.ToString() | Set-Content $OutFile -Encoding utf8; return }

$fields = 'System.Id,System.Title,System.WorkItemType,System.State,System.IterationPath,System.Parent,System.ChangedDate'
$items = (Invoke-RestMethod -Uri "$org/$project/_apis/wit/workitems?ids=$(($ids | Select-Object -First 200) -join ',')&fields=$fields&asOf=$asOf&api-version=7.1" -Headers $headers).value
$parentIds = $items.fields.'System.Parent' | Where-Object { $_ } | Sort-Object -Unique
$parents = @{}
if ($parentIds) {
    foreach ($p in (Invoke-RestMethod -Uri "$org/$project/_apis/wit/workitems?ids=$($parentIds -join ',')&fields=System.Id,System.Title,System.State&asOf=$asOf&api-version=7.1" -Headers $headers).value) {
        $parents[[int]$p.id] = "#$($p.id) $($p.fields.'System.Title') [$($p.fields.'System.State')]"
    }
}
foreach ($i in $items) {
    $f = $i.fields
    $sprint = ($f.'System.IterationPath' -split '\\')[-1]
    $parent = if ($f.'System.Parent') { " (under $($parents[[int]$f.'System.Parent']))" } else { '' }
    [void]$sb.AppendLine("- #$($i.id) [$($f.'System.WorkItemType')] $($f.'System.Title') -- $($f.'System.State'), $sprint, changed $(([datetime]$f.'System.ChangedDate').ToString('yyyy-MM-dd'))$parent")
}
$sb.ToString() | Set-Content $OutFile -Encoding utf8
