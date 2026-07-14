# Pester 3.4 (the Windows built-in). Legacy `Should Be` syntax, not `Should -Be`.
# Unit tests for the pure URL-parse/status-mapping/orchestration logic. `az` and the sidecar's
# HTTP endpoints are integration, proven by the morning smoke.

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'check-pr-status.ps1')   # dot-source: exposes the pure helpers, sweeps nothing

function NewJob {
    param([string]$Id, [string]$Status = 'PR', [string]$Pr = '', [string]$Note = '')
    [pscustomobject]@{ id = $Id; status = $Status; pr = $Pr; note = $Note }
}

Describe 'Get-PrCoordinates' {
    It 'parses an ADO PR url' {
        $c = Get-PrCoordinates 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/5814'
        $c.org | Should Be 'https://dev.azure.com/your-org'
        $c.id  | Should Be '5814'
    }
    It 'returns $null for junk' {
        Get-PrCoordinates 'not a url' | Should BeNullOrEmpty
        Get-PrCoordinates 'https://github.com/foo/bar/pull/5' | Should BeNullOrEmpty
    }
    It 'returns $null for empty/missing' {
        Get-PrCoordinates '' | Should BeNullOrEmpty
        Get-PrCoordinates $null | Should BeNullOrEmpty
    }
}

Describe 'Resolve-PrAction' {
    It 'completed -> done' { Resolve-PrAction 'completed' | Should Be 'done' }
    It 'abandoned -> parked' { Resolve-PrAction 'abandoned' | Should Be 'parked' }
    It 'active -> none' { Resolve-PrAction 'active' | Should Be 'none' }
    It 'unknown -> none' { Resolve-PrAction 'somethingElse' | Should Be 'none' }
}

Describe 'Invoke-PrStatusSweep' {
    It 'a completed PR yields a POST body with status=Done' {
        $jobs = @( (NewJob -Id 'a' -Pr 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/1') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) 'completed' }
        $r.completed | Should Be @('a')
        $r.posts.Count | Should Be 1
        $r.posts[0].id | Should Be 'a'
        $r.posts[0].status | Should Be 'Done'
    }
    It 'an abandoned PR yields a POST body with status=Parked and an annotated note' {
        $jobs = @( (NewJob -Id 'b' -Pr 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/2' -Note 'landed clean') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) 'abandoned' }
        $r.abandoned | Should Be @('b')
        $r.posts[0].status | Should Be 'Parked'
        $r.posts[0].note | Should Be 'landed clean [PR abandoned]'
    }
    It 'an active PR yields no POST' {
        $jobs = @( (NewJob -Id 'c' -Pr 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/3') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) 'active' }
        $r.posts.Count | Should Be 0
        $r.completed | Should BeNullOrEmpty
        $r.abandoned | Should BeNullOrEmpty
    }
    It 'a failing az call ($null status) is skipped, not posted' {
        $jobs = @( (NewJob -Id 'd' -Pr 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/4') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) $null }
        $r.skipped | Should Be @('d')
        $r.posts.Count | Should Be 0
    }
    It 'an unparseable pr url is skipped, not posted' {
        $jobs = @( (NewJob -Id 'e' -Pr 'not a url') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) 'completed' }
        $r.skipped | Should Be @('e')
        $r.posts.Count | Should Be 0
    }
    It 'ignores jobs not in PR status' {
        $jobs = @( (NewJob -Id 'f' -Status 'Done' -Pr 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/6') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) 'completed' }
        $r.checked | Should Be 0
    }
    It 'ignores PR-status jobs with no pr link' {
        $jobs = @( (NewJob -Id 'g' -Pr '') )
        $r = Invoke-PrStatusSweep -Jobs $jobs -GetStatus { param($org, $id) 'completed' }
        $r.checked | Should Be 0
    }
}
