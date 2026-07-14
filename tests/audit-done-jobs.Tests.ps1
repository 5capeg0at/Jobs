# Pester 3.4 (the Windows built-in). Legacy `Should Be` syntax, not `Should -Be`.
# Unit tests for the pure audit orchestration + config-map reading. git itself is the
# seam ($GetState scriptblock) and is faked here; the real seam is one merge-base call.

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'audit-done-jobs.ps1')   # dot-source: exposes helpers, audits nothing

function NewJob {
    param([string]$Id, [string]$Status = 'Done', [string]$Repo = 'example-repo', [string]$Branch = 'feature/x', [string]$Label = 'a job')
    [pscustomobject]@{ id = $Id; status = $Status; repo = $Repo; branch = $Branch; label = $Label }
}

$repos = @{ 'example-repo' = @{ path = 'C:\Repos\example-repo'; trunk = 'master' } }

Describe 'Invoke-DoneJobAudit' {
    It 'flags an unmerged Done branch as drift' {
        $rows = Invoke-DoneJobAudit -Jobs @(NewJob -Id 'a') -Repos $repos -GetState { 'unmerged' }
        $rows.Count | Should Be 1
        $rows[0].state | Should Be 'unmerged'
    }
    It 'passes a merged or deleted branch through with its state' {
        $rows = Invoke-DoneJobAudit -Jobs @((NewJob -Id 'a'), (NewJob -Id 'b')) -Repos $repos -GetState { param($p, $b, $t) if ($b -eq 'feature/x') { 'merged' } else { 'no-branch' } }
        $rows[0].state | Should Be 'merged'
    }
    It 'ignores non-Done jobs' {
        $rows = Invoke-DoneJobAudit -Jobs @(NewJob -Id 'a' -Status 'Review') -Repos $repos -GetState { 'unmerged' }
        @($rows).Count | Should Be 0
    }
    It 'skips jobs with no branch or no repo key' {
        $jobs = @((NewJob -Id 'a' -Branch ''), (NewJob -Id 'b' -Repo ''))
        $rows = Invoke-DoneJobAudit -Jobs $jobs -Repos $repos -GetState { 'unmerged' }
        @($rows).Count | Should Be 0
    }
    It 'skips PR-flow jobs (pr link set) without calling git - the pr-sweep owns those' {
        $j = NewJob -Id 'a'
        $j | Add-Member -NotePropertyName pr -NotePropertyValue 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/1'
        $rows = Invoke-DoneJobAudit -Jobs @($j) -Repos $repos -GetState { throw 'seam must not run' }
        $rows[0].state | Should Be 'pr-flow'
    }
    It 'marks a repo key missing from the map as unknown-repo without calling git' {
        $rows = Invoke-DoneJobAudit -Jobs @(NewJob -Id 'a' -Repo 'Nope') -Repos $repos -GetState { throw 'seam must not run' }
        $rows[0].state | Should Be 'unknown-repo'
    }
    It 'passes repo path, branch and trunk to the seam' {
        $seen = @{}
        Invoke-DoneJobAudit -Jobs @(NewJob -Id 'a') -Repos $repos -GetState { param($p, $b, $t) $seen.p = $p; $seen.b = $b; $seen.t = $t; 'merged' } | Out-Null
        $seen.p | Should Be 'C:\Repos\example-repo'
        $seen.b | Should Be 'feature/x'
        $seen.t | Should Be 'master'
    }
}

Describe 'Get-RepoMap' {
    It 'reads repos from the base config' {
        Set-Content -Path (Join-Path $TestDrive 'jobs.config.json') -Value '{"repos":{"example-repo":{"path":"C:\\Repos\\example-repo","trunk":"master"}}}'
        $map = Get-RepoMap -Root $TestDrive
        $map['example-repo'].trunk | Should Be 'master'
    }
    It 'local config repos win key-by-key' {
        Set-Content -Path (Join-Path $TestDrive 'jobs.config.json') -Value '{"repos":{"example-repo":{"path":"C:\\Repos\\example-repo","trunk":"master"}}}'
        Set-Content -Path (Join-Path $TestDrive 'jobs.config.local.json') -Value '{"repos":{"other-repo":{"path":"C:\\Repos\\other-repo","trunk":"master"}}}'
        $map = Get-RepoMap -Root $TestDrive
        $map.Keys.Count | Should Be 2
        $map['other-repo'].path | Should Be 'C:\Repos\other-repo'
    }
}
