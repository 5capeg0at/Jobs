<#
.SYNOPSIS
  Sweeps `PR`-status jobs for a linked Azure DevOps pull request and flips the job to
  Done/Parked once the PR has merged or been abandoned. No LLM in the loop — plain string
  comparison against `az` output.

.DESCRIPTION
  Fired by the sidecar's due-check on the configured cadence. Reads jobs via GET /jobs
  on the local sidecar (single source of truth, avoids a read-modify-write race on jobs.json),
  calls `az repos pr show` per candidate job, and POSTs status flips back through the sidecar
  so the atomic save + updatedAt stamping is reused.

  A plain fire-and-forget background script: it writes a one-line summary to stdout and
  exits 0/1.

.PARAMETER SidecarPort
  Local sidecar port. Defaults to jobs.config.json's port.
#>
[CmdletBinding()]
param(
    [int] $SidecarPort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PrCoordinates {
    # Pure: parse an ADO PR url into @{org;id}. $null for anything that doesn't match the
    # dev.azure.com/<account>/.../pullrequest/<id> shape (repo-agnostic — no config lookup).
    param([string] $Url)
    if (-not $Url) { return $null }
    if ($Url -match '^(https://dev\.azure\.com/[^/]+).*?/pullrequest/(\d+)') {
        return @{ org = $Matches[1]; id = $Matches[2] }
    }
    return $null
}

function Resolve-PrAction {
    # Pure: PR status -> job action. completed -> done, abandoned -> parked, anything else
    # (active, unrecognised) -> none (leave the job untouched).
    param([string] $PrStatus)
    switch ($PrStatus) {
        'completed' { return 'done' }
        'abandoned' { return 'parked' }
        default     { return 'none' }
    }
}

function Get-PrStatus {
    # The one-line `az` seam. Returns the raw status string, or $null on failure (auth
    # expiry, network) — Invoke-PrStatusSweep treats that as a soft per-job skip.
    param([string] $Org, [string] $Id)
    $out = & az repos pr show --id $Id --org $Org --query status -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$out).Trim()
}

function Invoke-PrStatusSweep {
    <#
      Pure orchestration over already-fetched job data: filters to PR-status jobs with a
      linked pr, resolves each via $GetStatus (an injectable scriptblock — production passes
      Get-PrStatus, tests substitute a stub), and decides the action. Returns the ids/counts
      plus the POST bodies the caller should send. No HTTP, no `az` — fully unit-testable.
    #>
    param(
        [array] $Jobs,
        [Parameter(Mandatory)] [scriptblock] $GetStatus
    )
    $candidates = @($Jobs | Where-Object { $_.status -eq 'PR' -and $_.PSObject.Properties['pr'] -and $_.pr })
    $completed = @(); $abandoned = @(); $skipped = @(); $posts = @()

    foreach ($job in $candidates) {
        $coords = Get-PrCoordinates $job.pr
        if (-not $coords) { $skipped += $job.id; continue }

        $prStatus = & $GetStatus $coords.org $coords.id
        if ($null -eq $prStatus) { $skipped += $job.id; continue }

        switch (Resolve-PrAction $prStatus) {
            'done' {
                $completed += $job.id
                $posts += @{ id = $job.id; status = 'Done' }
            }
            'parked' {
                $abandoned += $job.id
                $posts += @{ id = $job.id; status = 'Parked'; note = "$($job.note) [PR abandoned]".Trim() }
            }
            default { }
        }
    }

    return @{ checked = $candidates.Count; completed = $completed; abandoned = $abandoned; skipped = $skipped; posts = $posts }
}

# Dot-sourced (by the test) -> stop here, exposing the functions without running the sweep.
if ($MyInvocation.InvocationName -eq '.') { return }

$config = Get-Content -Raw (Join-Path $PSScriptRoot 'jobs.config.json') | ConvertFrom-Json
if (-not $SidecarPort) { $SidecarPort = $config.port }
$base = "http://localhost:$SidecarPort"

try {
    $data = Invoke-RestMethod -Uri "$base/jobs" -Method Get
} catch {
    Write-Host "[FAIL] could not read jobs from sidecar: $($_.Exception.Message)"
    exit 1
}

$sweep = Invoke-PrStatusSweep -Jobs @($data.jobs) -GetStatus { param($org, $id) Get-PrStatus -Org $org -Id $id }
Write-Host "checked $($sweep.checked) PR-status job(s): done $($sweep.completed.Count), parked $($sweep.abandoned.Count), skipped $($sweep.skipped.Count)"

foreach ($post in $sweep.posts) {
    Write-Host "job $($post.id): POST status=$($post.status)"
    Invoke-RestMethod -Uri "$base/jobs" -Method Post -ContentType 'application/json' -Body (ConvertTo-Json $post) | Out-Null
}
foreach ($id in $sweep.skipped) { Write-Host "job ${id}: skipped (unparseable PR url or az failure)" }

exit 0
