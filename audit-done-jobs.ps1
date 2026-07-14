<#
.SYNOPSIS
  Retro-time board audit: flags `Done` jobs whose branch still exists locally but was
  never merged into the repo's trunk.

.DESCRIPTION
  `Done` on the board is an assertion, not a fact. For repos with no PR flow (pure
  local merges) this audit is the check: for every Done job with a repo key + branch,
  ask git whether the branch is an ancestor of that repo's trunk.

  Read-only: reads jobs.json directly (no sidecar needed) and never writes anything.
  A branch that no longer exists is treated as fine — the merge protocol deletes
  branches after landing, so absence is the expected post-merge state.

.PARAMETER JobsRoot
  This repo's root (defaults to this script's parent). jobs.json and
  jobs.config.json(+.local) are read from here.

.OUTPUTS
  One line per audited job ([OK]/[DRIFT]/[SKIP]); exit 1 if any drift found.
#>
[CmdletBinding()]
param(
    [string] $JobsRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoMap {
    # repos map from jobs.config.json, with jobs.config.local.json keys winning
    # (same deep-merge contract as the sidecar: objects merge key-by-key).
    param([string] $Root)
    $cfg = Get-Content (Join-Path $Root 'jobs.config.json') -Raw | ConvertFrom-Json
    $map = @{}
    foreach ($p in $cfg.repos.PSObject.Properties) {
        $map[$p.Name] = @{ path = $p.Value.path; trunk = $p.Value.trunk }
    }
    $localPath = Join-Path $Root 'jobs.config.local.json'
    if (Test-Path $localPath) {
        $local = Get-Content $localPath -Raw | ConvertFrom-Json
        if ($local.PSObject.Properties['repos'] -and $local.repos) {
            foreach ($p in $local.repos.PSObject.Properties) {
                $map[$p.Name] = @{ path = $p.Value.path; trunk = $p.Value.trunk }
            }
        }
    }
    return $map
}

function Get-BranchMergeState {
    # The git seam. merged | unmerged | no-branch | no-repo.
    param([string] $RepoPath, [string] $Branch, [string] $Trunk)
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) { return 'no-repo' }
    & git -C $RepoPath rev-parse --verify --quiet "refs/heads/$Branch" *> $null
    if ($LASTEXITCODE -ne 0) { return 'no-branch' }
    & git -C $RepoPath merge-base --is-ancestor $Branch $Trunk *> $null
    if ($LASTEXITCODE -eq 0) { return 'merged' } else { return 'unmerged' }
}

function Invoke-DoneJobAudit {
    # Pure orchestration: which Done jobs are auditable, and what did the seam say.
    param($Jobs, [hashtable] $Repos, [scriptblock] $GetState)
    $rows = @()
    foreach ($j in @($Jobs)) {
        if (-not $j -or $j.status -ne 'Done') { continue }
        $branch  = if ($j.PSObject.Properties['branch']) { [string]$j.branch } else { '' }
        $repoKey = if ($j.PSObject.Properties['repo'])   { [string]$j.repo }   else { '' }
        if (-not $branch -or -not $repoKey) { continue }
        # PR-flow jobs are the pr-sweep's territory, and squash merges break local
        # ancestry anyway — this audit is for pure-local-merge repos.
        $pr = if ($j.PSObject.Properties['pr']) { [string]$j.pr } else { '' }
        if ($pr) {
            $rows += [pscustomobject]@{ id = $j.id; label = $j.label; repo = $repoKey; branch = $branch; state = 'pr-flow' }
            continue
        }
        $state = if ($Repos.ContainsKey($repoKey)) {
            & $GetState $Repos[$repoKey].path $branch $Repos[$repoKey].trunk
        } else { 'unknown-repo' }
        $rows += [pscustomobject]@{
            id = $j.id; label = $j.label; repo = $repoKey; branch = $branch; state = $state
        }
    }
    return ,$rows
}

if ($MyInvocation.InvocationName -eq '.') { return }

$jobsPath = Join-Path $JobsRoot 'jobs.json'
if (-not (Test-Path $jobsPath)) { Write-Host "[FAIL] no jobs.json at $jobsPath"; exit 2 }
$data  = Get-Content $jobsPath -Raw | ConvertFrom-Json
$repos = Get-RepoMap -Root $JobsRoot
$rows  = Invoke-DoneJobAudit -Jobs @($data.jobs) -Repos $repos -GetState {
    param($p, $b, $t) Get-BranchMergeState -RepoPath $p -Branch $b -Trunk $t
}

$drift = @($rows | Where-Object { $_.state -eq 'unmerged' })
foreach ($row in $rows) {
    $tag = switch ($row.state) {
        'unmerged'  { '[DRIFT]' }
        'merged'    { '[OK]   ' }
        'no-branch' { '[OK]   ' }
        default     { '[SKIP] ' }
    }
    Write-Host ("{0} {1}  {2} ({3} @ {4}) -> {5}" -f $tag, $row.id, $row.label, $row.repo, $row.branch, $row.state)
}
if ($drift.Count -gt 0) {
    Write-Host ("[FAIL] {0} Done job(s) with unmerged branches - board drift" -f $drift.Count)
    exit 1
}
Write-Host ("[OK] no Done-job drift ({0} audited)" -f @($rows).Count)
exit 0
