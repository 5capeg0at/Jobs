# Unit tests for the shadow-pane parsers: stage-lined logs and the day markdown. Pure functions,
# no listener, no scheduled tasks. Same Pester 3.4 syntax as the rest of the suite.
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'jobs-sidecar.ps1')
$fx = Join-Path $PSScriptRoot 'fixtures\shadow'

Describe 'Read-ShadowLog' {
    It 'marks every stage done on a clean morning run' {
        $r = Read-ShadowLog (Join-Path $fx '2026-01-05-morning.log') 'morning'
        $r.ok | Should Be $true
        ($r.stages | Where-Object { $_.state -ne 'done' } | Measure-Object).Count | Should Be 0
        $r.startedAt | Should Be '06:15:01'
        $r.finishedAt | Should Be '06:19:42'
    }
    It 'marks the first missing stage failed after a [FAIL] line' {
        $r = Read-ShadowLog (Join-Path $fx '2026-01-05-evening.log') 'evening'
        $r.ok | Should Be $false
        ($r.stages | Where-Object key -eq 'claude').state | Should Be 'done'
        ($r.stages | Where-Object key -eq 'out').state | Should Be 'failed'
        ($r.stages | Where-Object key -eq 'dm').state | Should Be 'pending'
    }
    It 'returns null when the log does not exist' {
        Read-ShadowLog (Join-Path $fx 'nope.log') 'morning' | Should Be $null
    }
}

Describe 'Read-ShadowDay' {
    $ledger = Get-Content (Join-Path $fx 'ledger.json') -Raw | ConvertFrom-Json
    $d = Read-ShadowDay $fx '2026-01-05' $ledger
    It 'parses the plan bullets with their disposition' {
        $d.plan.Count | Should Be 4
        ($d.plan | Where-Object task -eq 'pre-standup-digest').disposition | Should Be 'do'
        ($d.plan | Where-Object task -eq 'standup, 09:00').disposition | Should Be 'note'
        ($d.plan | Where-Object task -eq 'red-pipeline triage').disposition | Should Be 'off'
    }
    It 'reads the scorecard counts from the prose' {
        $d.score.matched | Should Be 2
        $d.score.missed | Should Be 1
        $d.hasCompare | Should Be $true
    }
    It 'lists tweaks, questions and needs' {
        $d.tweaks.Count | Should Be 2
        $d.questions.Count | Should Be 2
        $d.questions[1].text | Should Be 'Why was refining skipped?'
        $d.needs.Count | Should Be 1
    }
    It 'joins ledger rows and Slack permalinks for the day' {
        $d.compare.Count | Should Be 1
        $d.slack[0].url | Should Be 'https://x/p12'
    }
    It 'attaches both run logs' {
        $d.runs.morning.ok | Should Be $true
        $d.runs.evening.failed | Should Be $true
    }
}


