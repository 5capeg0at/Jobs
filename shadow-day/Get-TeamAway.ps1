<#
.SYNOPSIS
Writes a markdown list of the team absences logged under The Green Mile (PBI #17036).

.DESCRIPTION
The team logs every absence as a child task of The Green Mile, titled in free text ("Dan on leave -
Thursday 17th September - back Tuesday 13th October"). Meeting requests aren't cancelled when
someone is away, so this is what lets a shadow run tell a calendared 1:1 that happened from one
that didn't. Titles are passed through verbatim for the model to read; parsing free-text dates here
would be brittle for no gain. Read-only (bearer token from `az account get-access-token`).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutFile,
    # UTC instant to read the board as of, so a dry run against a past day can't see later entries.
    [datetime]$AsOfUtc = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
$org = 'https://dev.azure.com/FINNZ'; $project = 'FishServe'; $greenMile = 17036
$token = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
if (-not $token) { throw 'No ADO token; run az login' }
$headers = @{ Authorization = "Bearer $token" }

$asOf = $AsOfUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
# Absences are logged ahead and closed when the person is back, so a 45-day window on creation
# covers anything in force today without dragging in the parent's whole history.
$floor = $AsOfUtc.AddDays(-45).ToString('yyyy-MM-dd')
$wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$project' AND [System.Parent] = $greenMile AND [System.CreatedDate] >= '$floor' AND [System.State] <> 'Removed' AND ([System.Title] CONTAINS 'leave' OR [System.Title] CONTAINS 'away' OR [System.Title] CONTAINS 'conference' OR [System.Title] CONTAINS ' off') ASOF '$asOf'" } | ConvertTo-Json
$ids = (Invoke-RestMethod -Method Post -Uri "$org/$project/_apis/wit/wiql?api-version=7.1" -Headers $headers -ContentType 'application/json' -Body $wiql).workItems.id

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Team away list from The Green Mile #$greenMile (as of $asOf)")
[void]$sb.AppendLine()
if (-not $ids) { [void]$sb.AppendLine('(none logged)') }
else {
    $items = (Invoke-RestMethod -Uri "$org/$project/_apis/wit/workitems?ids=$($ids -join ',')&fields=System.Id,System.Title,System.State,System.CreatedDate&asOf=$asOf&api-version=7.1" -Headers $headers).value
    foreach ($i in $items | Sort-Object { $_.fields.'System.CreatedDate' }) {
        [void]$sb.AppendLine("- #$($i.id) $($i.fields.'System.Title') -- $($i.fields.'System.State'), logged $(([datetime]$i.fields.'System.CreatedDate').ToString('yyyy-MM-dd'))")
    }
}
$sb.ToString() | Set-Content $OutFile -Encoding utf8
