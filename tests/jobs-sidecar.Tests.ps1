# Pester 3.4 (the Windows built-in). Legacy `Should Be` syntax, not `Should -Be`.
# Dot-sourcing jobs-sidecar.ps1 skips the listener (run-as-script guard) and
# exposes the pure helpers directly.

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'jobs-sidecar.ps1')

Describe 'Merge-JobUpsert (rich board, jobs.json)' {
    It 'creates a fresh job with the given NextNum and defaults' {
        $body = [pscustomobject]@{ label = 'new job' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.num    | Should Be 1
        $j.status | Should Be 'Planned'
    }

    It 'stamps a pr value on create' {
        $body = [pscustomobject]@{ label = 'new job'; pr = 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/1' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.pr | Should Be 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/1'
    }

    It 'defaults pr to empty on create when omitted' {
        $body = [pscustomobject]@{ label = 'new job' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.pr | Should Be ''
    }

    It 'edits in place, falling back to the existing value for omitted fields' {
        $existing = [pscustomobject]@{ id='x'; num=3; label='old'; note='n'; status='Planned'; repo='example-repo'; branch='master'; pr=''; docs=@(); createdAt='2026-07-01T00:00:00Z'; updatedAt='2026-07-01T00:00:00Z' }
        $body = [pscustomobject]@{ id = 'x'; status = 'Done' }   # only status changes
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.label  | Should Be 'old'
        $j.status | Should Be 'Done'
        $j.num    | Should Be 3   # untouched — editing never invents a num
    }

    It 'preserves an existing pr value when the update body omits it' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr='https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/2'; status='PR'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; status = 'Done' }   # no pr field in the body
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.pr | Should Be 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/2'
        $j.status | Should Be 'Done'
    }

    It 'updates pr on an existing job predating the field' {
        $existing = [pscustomobject]@{ id='y'; label='j'; branch='b'; repo='example-repo'; status='PR'; note=''; docs=@() }   # no pr property at all
        $body = [pscustomobject]@{ id = 'y'; pr = 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/3' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.pr | Should Be 'https://dev.azure.com/your-org/YourProject/_git/example-repo/pullrequest/3'
    }

    It 'stamps discoveredFrom on create' {
        $body = [pscustomobject]@{ label = 'spawned job'; discoveredFrom = 'b9c0d1e2' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.discoveredFrom | Should Be 'b9c0d1e2'
    }

    It 'leaves discoveredFrom empty on create when omitted, marking a root job' {
        $body = [pscustomobject]@{ label = 'new job' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.discoveredFrom | Should Be ''
    }

    It 'preserves an existing discoveredFrom when the update body omits it' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; discoveredFrom='b9c0d1e2'; status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; status = 'Done' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.discoveredFrom | Should Be 'b9c0d1e2'
        $j.status | Should Be 'Done'
    }

    It 'sets discoveredFrom on an existing job predating the field' {
        $existing = [pscustomobject]@{ id='z'; label='j'; branch='b'; repo='example-repo'; status='Planned'; note=''; docs=@() }   # no discoveredFrom property at all
        $body = [pscustomobject]@{ id = 'z'; discoveredFrom = 'f1a2b3c4' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.discoveredFrom | Should Be 'f1a2b3c4'
    }

    It 'stamps blockedBy job numbers on create' {
        $body = [pscustomobject]@{ label = 'gated job'; blockedBy = @(137, 19) }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        @($j.blockedBy).Count | Should Be 2
        $j.blockedBy[0] | Should Be 137
    }

    It 'stores blockedBy as ints so a "#N" lookup never compares string to number' {
        $body = [pscustomobject]@{ label = 'gated job'; blockedBy = @('137') }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.blockedBy[0] -is [int] | Should Be $true
    }

    It 'defaults blockedBy to empty on create when omitted' {
        $body = [pscustomobject]@{ label = 'new job' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        @($j.blockedBy).Count | Should Be 0
    }

    It 'preserves existing blockers when the update body omits blockedBy' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; blockedBy=@(137); status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; status = 'In progress' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        @($j.blockedBy).Count | Should Be 1
        $j.blockedBy[0] | Should Be 137
    }

    It 'clears blockers when the update body passes an empty array' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; blockedBy=@(137); status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; blockedBy = @() }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        @($j.blockedBy).Count | Should Be 0
    }

    It 'sets blockedBy on an existing job predating the field' {
        $existing = [pscustomobject]@{ id='z'; label='j'; branch='b'; repo='example-repo'; status='Planned'; note=''; docs=@() }   # no blockedBy property at all
        $body = [pscustomobject]@{ id = 'z'; blockedBy = @(137) }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.blockedBy[0] | Should Be 137
    }

    It 'stamps underminedBy job numbers on create, as ints' {
        $body = [pscustomobject]@{ label = 'challenged job'; underminedBy = @('142') }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        @($j.underminedBy).Count | Should Be 1
        $j.underminedBy[0] | Should Be 142
        $j.underminedBy[0] -is [int] | Should Be $true
    }

    It 'defaults underminedBy to empty on create when omitted' {
        $body = [pscustomobject]@{ label = 'plain job' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        @($j.underminedBy).Count | Should Be 0
    }

    It 'preserves underminedBy when the update body omits it' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; underminedBy=@(142); status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; note = 'still challenged' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        @($j.underminedBy).Count | Should Be 1
        $j.underminedBy[0] | Should Be 142
    }

    It 'clears underminedBy with an explicit empty array — the premise survived' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; underminedBy=@(142); status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; underminedBy = @() }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        @($j.underminedBy).Count | Should Be 0
    }

    It 'sets underminedBy on an existing job predating the field' {
        $existing = [pscustomobject]@{ id='z'; label='j'; branch='b'; repo='example-repo'; status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'z'; underminedBy = @(142) }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.underminedBy[0] | Should Be 142
    }

    It 'stamps type on create' {
        $body = [pscustomobject]@{ label = 'typed job'; type = 'research' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.type | Should Be 'research'
    }

    It 'preserves type when the update body omits it' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; type='task'; status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; note = 'progress' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.type | Should Be 'task'
    }

    It 'sets type on an existing job predating the field' {
        $existing = [pscustomobject]@{ id='z'; label='j'; branch='b'; repo='example-repo'; status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'z'; type = 'research' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.type | Should Be 'research'
    }

    It 'defaults next to false on create' {
        $body = [pscustomobject]@{ label = 'plain job' }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.next | Should Be $false
    }

    It 'stamps next true on create' {
        $body = [pscustomobject]@{ label = 'short-listed job'; next = $true }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        $j.next | Should Be $true
    }

    It 'preserves next when the update body omits it' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; next=$true; status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; note = 'progress' }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.next | Should Be $true
    }

    It 'clears next with an explicit false — coming off the short list' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; pr=''; next=$true; status='Planned'; note=''; docs=@() }
        $body = [pscustomobject]@{ id = 'x'; next = $false }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        $j.next | Should Be $false
    }
}

Describe 'Get-BlockedByProblem (blockedBy validation on upsert)' {
    It 'accepts an omitted blockedBy — most jobs gate on nothing' {
        Get-BlockedByProblem $null | Should BeNullOrEmpty
    }

    It 'accepts an empty array, which is how blockers get cleared' {
        Get-BlockedByProblem @() | Should BeNullOrEmpty
    }

    It 'accepts an array of job numbers' {
        Get-BlockedByProblem @(137, 19) | Should BeNullOrEmpty
    }

    It 'accepts numeric strings, since JSON from a shell often quotes numbers' {
        Get-BlockedByProblem @('137') | Should BeNullOrEmpty
    }

    It 'rejects a bare number — a single blocker still travels as an array' {
        Get-BlockedByProblem 137 | Should Match 'array'
    }

    It 'rejects a string, including one that looks like a list' {
        Get-BlockedByProblem '137,19' | Should Match 'array'
    }

    It 'names the offending entry when one is not a job number' {
        $problem = Get-BlockedByProblem @(137, 'ce4b2e6e')
        $problem | Should Match 'ce4b2e6e'
        $problem | Should Match 'job number'
    }

    It 'rejects a job id, the likeliest wrong thing to pass' {
        Get-BlockedByProblem @('0628cb55') | Should Match 'job number'
    }
}

Describe 'Get-BlockedByProblem with -FieldName (shared job-number-array validation)' {
    It 'names the field in the not-an-array message' {
        Get-BlockedByProblem 142 -FieldName 'underminedBy' | Should Match 'underminedBy must be an array'
    }
    It 'names the field in the bad-entry message' {
        Get-BlockedByProblem @('ce4b2e6e') -FieldName 'underminedBy' | Should Match "underminedBy entry 'ce4b2e6e'"
    }
}

Describe 'Get-TypeProblem (type validation on upsert)' {
    It 'accepts an omitted type — every pre-existing job is untyped' {
        Get-TypeProblem $null | Should BeNullOrEmpty
    }
    It 'accepts an empty string as untyped' {
        Get-TypeProblem '' | Should BeNullOrEmpty
    }
    It 'accepts task' {
        Get-TypeProblem 'task' | Should BeNullOrEmpty
    }
    It 'accepts research' {
        Get-TypeProblem 'research' | Should BeNullOrEmpty
    }
    It 'rejects an unknown type naming the valid two' {
        $problem = Get-TypeProblem 'prototype'
        $problem | Should Match "task"
        $problem | Should Match "research"
        $problem | Should Match "prototype"
    }
}

Describe 'Get-NextProblem (next-flag validation on upsert)' {
    It 'accepts an omitted next' {
        Get-NextProblem $null | Should BeNullOrEmpty
    }
    It 'accepts true and false' {
        Get-NextProblem $true  | Should BeNullOrEmpty
        Get-NextProblem $false | Should BeNullOrEmpty
    }
    It 'rejects a non-boolean — a truthy string would silently jump the queue' {
        Get-NextProblem 'yes' | Should Match 'true or false'
    }
}

Describe 'Get-DoneGateProblem (closing artefact required on the way into Done)' {
    It 'ignores upserts that do not land on Done' {
        $body = [pscustomobject]@{ id='x'; status='In progress' }
        $existing = [pscustomobject]@{ id='x'; type='research'; status='Planned'; note=''; pr='' }
        Get-DoneGateProblem $body $existing | Should BeNullOrEmpty
    }

    It 'ignores a job already Done — nothing closed is held hostage' {
        $body = [pscustomobject]@{ id='x'; label='renamed' }
        $existing = [pscustomobject]@{ id='x'; type='research'; status='Done'; note=''; pr='' }
        Get-DoneGateProblem $body $existing | Should BeNullOrEmpty
    }

    It 'blocks research -> Done with no note: the finding is the artefact' {
        $body = [pscustomobject]@{ id='x'; status='Done' }
        $existing = [pscustomobject]@{ id='x'; type='research'; status='In progress'; note=''; pr='' }
        Get-DoneGateProblem $body $existing | Should Match 'note'
    }

    It 'passes research -> Done when the body carries the finding' {
        $body = [pscustomobject]@{ id='x'; status='Done'; note='Finding: the premise held.' }
        $existing = [pscustomobject]@{ id='x'; type='research'; status='In progress'; note=''; pr='' }
        Get-DoneGateProblem $body $existing | Should BeNullOrEmpty
    }

    It 'passes research -> Done on a stored note when the body omits it' {
        $body = [pscustomobject]@{ id='x'; status='Done' }
        $existing = [pscustomobject]@{ id='x'; type='research'; status='In progress'; note='Finding already written.'; pr='' }
        Get-DoneGateProblem $body $existing | Should BeNullOrEmpty
    }

    It 'blocks task -> Done with neither pr nor note' {
        $body = [pscustomobject]@{ id='x'; status='Done' }
        $existing = [pscustomobject]@{ id='x'; type='task'; status='In progress'; note=''; pr='' }
        Get-DoneGateProblem $body $existing | Should Match 'pr'
    }

    It 'passes task -> Done on a pr alone — the merge sweep path' {
        $body = [pscustomobject]@{ id='x'; status='Done' }
        $existing = [pscustomobject]@{ id='x'; type='task'; status='PR'; note=''; pr='https://dev.azure.com/FINNZ/FishServe/_git/Kupe/pullrequest/5814' }
        Get-DoneGateProblem $body $existing | Should BeNullOrEmpty
    }

    It 'treats untyped like task — pr or note passes, neither blocks' {
        $blocked = [pscustomobject]@{ id='x'; status='Done' }
        $bare    = [pscustomobject]@{ id='x'; status='In progress'; note=''; pr='' }
        Get-DoneGateProblem $blocked $bare | Should Match 'pr'
        $noted   = [pscustomobject]@{ id='x'; status='In progress'; note='wrapped up'; pr='' }
        Get-DoneGateProblem $blocked $noted | Should BeNullOrEmpty
    }

    It 'gates a job created straight into Done' {
        $body = [pscustomobject]@{ label='drive-by'; status='Done' }
        Get-DoneGateProblem $body $null | Should Match 'pr'
    }

    It 'blocks whitespace-only notes — a blank line is not a finding' {
        $body = [pscustomobject]@{ id='x'; status='Done'; note='   ' }
        $existing = [pscustomobject]@{ id='x'; type='research'; status='In progress'; note=''; pr='' }
        Get-DoneGateProblem $body $existing | Should Match 'note'
    }
}

Describe 'Get-NextJobNum (monotonic job numbering)' {
    It 'starts at 1 on an empty board' {
        Get-NextJobNum ([pscustomobject]@{ jobs = @() }) | Should Be 1
    }

    It 'follows the highest num when no nextNum is stored' {
        $data = [pscustomobject]@{ jobs = @(
            [pscustomobject]@{ id='a'; num=100 },
            [pscustomobject]@{ id='b'; num=101 }
        ) }
        Get-NextJobNum $data | Should Be 102
    }

    It 'ignores jobs that predate the num field' {
        $data = [pscustomobject]@{ jobs = @(
            [pscustomobject]@{ id='a' },
            [pscustomobject]@{ id='b'; num=7 }
        ) }
        Get-NextJobNum $data | Should Be 8
    }

    It 'treats a stored nextNum as a floor, so a deleted top job never gets reissued' {
        # #101 created then deleted: nextNum stayed at 102 while max(num) fell back to 100.
        $data = [pscustomobject]@{ nextNum = 102; jobs = @([pscustomobject]@{ id='a'; num=100 }) }
        Get-NextJobNum $data | Should Be 102
    }

    It 'wins over a stale nextNum that trails the board' {
        $data = [pscustomobject]@{ nextNum = 5; jobs = @([pscustomobject]@{ id='a'; num=100 }) }
        Get-NextJobNum $data | Should Be 101
    }

    It 'reads a num stored as a string' {
        $data = [pscustomobject]@{ jobs = @([pscustomobject]@{ id='a'; num='99' }) }
        Get-NextJobNum $data | Should Be 100
    }
}

Describe 'Test-KnownRepo (repo key validation on upsert)' {
    $repos = [pscustomobject]@{
        'example-repo' = [pscustomobject]@{ path='C:\x'; trunk='main' }
        'Jobs'         = [pscustomobject]@{ path='C:\y'; trunk='master' }
    }

    It 'accepts a key present in the repos map' {
        Test-KnownRepo 'Jobs' $repos | Should Be $true
    }

    It 'rejects a key that is not' {
        Test-KnownRepo 'Kupe' $repos | Should Be $false
    }

    It 'accepts an omitted repo — pinning one is optional' {
        Test-KnownRepo ''   $repos | Should Be $true
        Test-KnownRepo $null $repos | Should Be $true
    }

    It 'rejects any key when the config carries no repos map at all' {
        Test-KnownRepo 'Jobs' $null | Should Be $false
    }
}

Describe 'Merge-RepoUpsert (local config, jobs.config.local.json)' {
    It 'seeds a repos map when the local config does not exist yet' {
        $c = Merge-RepoUpsert -LocalConfig $null -Key 'Kupe' -Path 'C:\Repos\Kupe' -Trunk 'master'
        $c.repos.Kupe.path  | Should Be 'C:\Repos\Kupe'
        $c.repos.Kupe.trunk | Should Be 'master'
        $c._comment | Should Not BeNullOrEmpty
    }

    It 'adds a repo alongside the existing ones' {
        $local = '{"repos":{"Bridge":{"path":"C:\\Repos\\Bridge","trunk":"master"}}}' | ConvertFrom-Json
        $c = Merge-RepoUpsert -LocalConfig $local -Key 'Kupe' -Path 'C:\Repos\Kupe' -Trunk 'main'
        $c.repos.Bridge.path | Should Be 'C:\Repos\Bridge'
        $c.repos.Kupe.trunk  | Should Be 'main'
    }

    It 'overwrites a repo registered under the same key' {
        $local = '{"repos":{"Kupe":{"path":"D:\\old","trunk":"main"}}}' | ConvertFrom-Json
        $c = Merge-RepoUpsert -LocalConfig $local -Key 'Kupe' -Path 'C:\Repos\Kupe' -Trunk 'master'
        @($c.repos.PSObject.Properties).Count | Should Be 1
        $c.repos.Kupe.path  | Should Be 'C:\Repos\Kupe'
        $c.repos.Kupe.trunk | Should Be 'master'
    }

    It 'carries unrelated keys through untouched' {
        $local = '{"_comment":"mine","ado":{"org":"https://dev.azure.com/acme"},"port":7800}' | ConvertFrom-Json
        $c = Merge-RepoUpsert -LocalConfig $local -Key 'Kupe' -Path 'C:\Repos\Kupe' -Trunk 'master'
        $c._comment | Should Be 'mine'
        $c.ado.org  | Should Be 'https://dev.azure.com/acme'
        $c.port     | Should Be 7800
        $c.repos.Kupe.path | Should Be 'C:\Repos\Kupe'
    }
}

# --- ADO pure-helper tests ------

function NewWi { param([hashtable]$Fields); [pscustomobject]@{ fields = [pscustomobject]$Fields } }

Describe 'ConvertTo-PlainText' {
    It 'returns empty for null/empty' {
        ConvertTo-PlainText $null | Should Be ''
        ConvertTo-PlainText ''   | Should Be ''
    }
    It 'strips tags and keeps the text' {
        $r = ConvertTo-PlainText '<div><ul><li>One</li><li>Two</li></ul></div>'
        $r | Should Match 'One'
        $r | Should Match 'Two'
        $r | Should Not Match '<'
    }
    It 'decodes common entities' {
        ConvertTo-PlainText 'a &amp; b &lt;c&gt; &quot;d&quot;' | Should Be 'a & b <c> "d"'
    }
    It 'turns <br> into a newline' {
        (ConvertTo-PlainText 'line1<br>line2') -split "`n" | Should Be @('line1','line2')
    }
    It 'passes plain text / markdown through untouched' {
        $md = 'See [the page](https://example.com/x) for detail.'
        ConvertTo-PlainText $md | Should Be $md
    }
    It 'collapses &nbsp; to a space' {
        ConvertTo-PlainText 'a&nbsp;b' | Should Be 'a b'
    }
}

Describe 'ConvertTo-AdoTasks' {
    $items = @(
        (NewWi @{ 'System.Id'=1; 'System.Title'='a'; 'System.State'='Done';        'System.Parent'=100 }),
        (NewWi @{ 'System.Id'=2; 'System.Title'='b'; 'System.State'='In Progress'; 'System.Parent'=100 }),
        (NewWi @{ 'System.Id'=3; 'System.Title'='c'; 'System.State'='To Do';       'System.Parent'=101 }),
        (NewWi @{ 'System.Id'=4; 'System.Title'='d'; 'System.State'='Done';        'System.Parent'=101 })
    )
    $split = ConvertTo-AdoTasks $items

    It 'counts Done tasks' { $split.done | Should Be 2 }
    It 'keeps only open tasks' { @($split.open).Count | Should Be 2 }
    It 'open tasks carry their parent id' {
        ($split.open | Where-Object { $_.id -eq 2 }).parent | Should Be 100
    }
}

Describe 'ConvertTo-AdoStories' {
    # Three open tasks across three candidate parents; story 300 is New (must be filtered out),
    # story 303 is Ready but has no open task (must drop), 301/302 are In Progress.
    $open = @(
        [pscustomobject]@{ id=10; title='t-todo';  state='To Do';       parent=301; description='' },
        [pscustomobject]@{ id=11; title='t-prog';  state='In Progress'; parent=301; description='' },
        [pscustomobject]@{ id=12; title='t-other'; state='To Do';       parent=302; description='' },
        [pscustomobject]@{ id=13; title='t-new';   state='To Do';       parent=300; description='' }
    )
    $stories = @(
        (NewWi @{ 'System.Id'=300; 'System.Title'='new story';   'System.State'='New';         'Microsoft.VSTS.Common.BacklogPriority'=1000 }),
        (NewWi @{ 'System.Id'=301; 'System.Title'='prog hi-pri'; 'System.State'='In Progress'; 'Microsoft.VSTS.Common.BacklogPriority'=3000; 'System.Tags'='Infra; Security' }),
        (NewWi @{ 'System.Id'=302; 'System.Title'='ready story'; 'System.State'='Ready';       'Microsoft.VSTS.Common.BacklogPriority'=1000 }),
        (NewWi @{ 'System.Id'=303; 'System.Title'='ready empty'; 'System.State'='Ready';       'Microsoft.VSTS.Common.BacklogPriority'=2000 })
    )
    $shaped = @(ConvertTo-AdoStories $open $stories 'http://wi/')

    It 'excludes non-{In Progress,Ready} stories' {
        ($shaped | Where-Object { $_.id -eq 300 }) | Should BeNullOrEmpty
    }
    It 'drops stories with no open tasks' {
        ($shaped | Where-Object { $_.id -eq 303 }) | Should BeNullOrEmpty
    }
    It 'renders the two stories that survive' { $shaped.Count | Should Be 2 }
    It 'sorts stories by sprint order (BacklogPriority ascending)' {
        $shaped[0].id | Should Be 302   # backlogPriority 1000 before 3000
        $shaped[1].id | Should Be 301
    }
    It 'sorts tasks In Progress before To Do' {
        $s301 = $shaped | Where-Object { $_.id -eq 301 }
        $s301.tasks[0].state | Should Be 'In Progress'
        $s301.tasks[1].state | Should Be 'To Do'
    }
    It 'splits tags into an array' {
        $s301 = $shaped | Where-Object { $_.id -eq 301 }
        @($s301.tags).Count | Should Be 2
        $s301.tags[0] | Should Be 'Infra'
    }
    It 'builds work-item urls' {
        ($shaped | Where-Object { $_.id -eq 302 }).url | Should Be 'http://wi/302'
    }
    It 'nulls acceptance criteria when absent' {
        ($shaped | Where-Object { $_.id -eq 301 }).ac | Should BeNullOrEmpty
    }
}

Describe 'Resolve-StaticFile (briefs static route)' {
    $briefsDir = Join-Path $TestDrive 'briefs'
    New-Item -ItemType Directory -Path $briefsDir -Force | Out-Null
    Set-Content -Path (Join-Path $briefsDir '2026-07-10-morning-brief.html') -Value '<html>old</html>'
    Set-Content -Path (Join-Path $briefsDir '2026-07-12-morning-brief.html') -Value '<html>new</html>'
    Set-Content -Path (Join-Path $briefsDir 'shot.png') -Value 'not-really-png'

    It 'serves a named brief file from the briefs dir' {
        $f = Resolve-StaticFile -Root $briefsDir -RequestedPath 'shot.png' -LatestPattern '*-morning-brief.html'
        $f | Should Be (Join-Path $briefsDir 'shot.png')
    }

    It 'latest.html resolves to the newest *-morning-brief.html' {
        $f = Resolve-StaticFile -Root $briefsDir -RequestedPath 'latest.html' -LatestPattern '*-morning-brief.html'
        $f | Should Be (Join-Path $briefsDir '2026-07-12-morning-brief.html')
    }

    It 'empty request path also resolves to the latest brief' {
        $f = Resolve-StaticFile -Root $briefsDir -RequestedPath '' -LatestPattern '*-morning-brief.html'
        $f | Should Be (Join-Path $briefsDir '2026-07-12-morning-brief.html')
    }

    It 'rejects a traversal attempt escaping the briefs dir' {
        $f = Resolve-StaticFile -Root $briefsDir -RequestedPath '..%2fjobs.json' -LatestPattern '*-morning-brief.html'
        $f | Should Be $null
    }

    It 'returns null for a missing file' {
        $f = Resolve-StaticFile -Root $briefsDir -RequestedPath 'nope.html' -LatestPattern '*-morning-brief.html'
        $f | Should Be $null
    }

    It 'returns null when the folder does not exist at all' {
        $f = Resolve-StaticFile -Root (Join-Path $TestDrive 'nothing-here') -RequestedPath 'latest.html' -LatestPattern '*-morning-brief.html'
        $f | Should Be $null
    }
}

Describe 'Resolve-StaticFile across the factory-brief rename' {
    # The brief was renamed from "morning brief" to "factory brief" (the morning read
    # is the Almanac now). Every brief written before the rename is still on disk under
    # the old name, so latest.html has to keep seeing both - otherwise the rename
    # silently orphans the whole archive and the route 404s until the next run.
    $dir = Join-Path $TestDrive 'renamed'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $patterns = @('*-factory-brief.html', '*-morning-brief.html')

    It 'still finds an old brief when no new-style one exists yet' {
        Set-Content -Path (Join-Path $dir '2026-07-20-morning-brief.html') -Value '<html>old</html>'
        $f = Resolve-StaticFile -Root $dir -RequestedPath 'latest.html' -LatestPattern $patterns
        $f | Should Be (Join-Path $dir '2026-07-20-morning-brief.html')
    }

    It 'prefers the newer file regardless of which naming it uses' {
        Set-Content -Path (Join-Path $dir '2026-07-25-factory-brief.html') -Value '<html>new</html>'
        $f = Resolve-StaticFile -Root $dir -RequestedPath 'latest.html' -LatestPattern $patterns
        $f | Should Be (Join-Path $dir '2026-07-25-factory-brief.html')
    }

    It 'an older new-style file does not beat a newer old-style one' {
        Set-Content -Path (Join-Path $dir '2026-07-28-morning-brief.html') -Value '<html>newest</html>'
        $f = Resolve-StaticFile -Root $dir -RequestedPath 'latest.html' -LatestPattern $patterns
        $f | Should Be (Join-Path $dir '2026-07-28-morning-brief.html')
    }
}

Describe 'Resolve-StaticFile (almanac static route)' {
    # The two routes share one resolver, so what is worth testing separately is that
    # the newest-file pattern really is per-route: an almanac request must not fall
    # through to a brief sitting in its own folder, and vice versa.
    $almanacDir = Join-Path $TestDrive 'almanac'
    New-Item -ItemType Directory -Path $almanacDir -Force | Out-Null
    Set-Content -Path (Join-Path $almanacDir '2026-07-26-almanac.html') -Value '<html>yesterday</html>'
    Set-Content -Path (Join-Path $almanacDir '2026-07-27-almanac.html') -Value '<html>today</html>'
    Set-Content -Path (Join-Path $almanacDir '2026-07-28-morning-brief.html') -Value '<html>not mine</html>'

    It 'latest.html resolves to the newest *-almanac.html' {
        $f = Resolve-StaticFile -Root $almanacDir -RequestedPath 'latest.html' -LatestPattern '*-almanac.html'
        $f | Should Be (Join-Path $almanacDir '2026-07-27-almanac.html')
    }

    It 'ignores a newer file that is not an almanac' {
        $f = Resolve-StaticFile -Root $almanacDir -RequestedPath 'latest.html' -LatestPattern '*-almanac.html'
        $f | Should Not Be (Join-Path $almanacDir '2026-07-28-morning-brief.html')
    }

    It 'rejects a traversal attempt escaping the almanac dir' {
        $f = Resolve-StaticFile -Root $almanacDir -RequestedPath '..%2fjobs.json' -LatestPattern '*-almanac.html'
        $f | Should Be $null
    }
}

Describe 'Get-StaticContentType' {
    It 'maps .html to text/html' { Get-StaticContentType 'x.html' | Should Be 'text/html; charset=utf-8' }
    It 'maps .png to image/png' { Get-StaticContentType 'x.png' | Should Be 'image/png' }
    It 'maps .svg to image/svg+xml' { Get-StaticContentType 'x.svg' | Should Be 'image/svg+xml' }
    It 'falls back to octet-stream for unknown extensions' { Get-StaticContentType 'x.bin' | Should Be 'application/octet-stream' }
}

Describe 'Merge-JobUpsert docsAppend (merge, never clobber)' {
    It 'appends new entries to the existing docs instead of replacing them' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; status='Review'; note=''; docs=@([pscustomobject]@{ name='SPEC'; path='C:\d\spec.md'; type='md' }) }
        $body = [pscustomobject]@{ id='x'; docsAppend=@([pscustomobject]@{ name='HANDOVER'; path='C:\d\handover.md'; type='md' }) }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        @($j.docs).Count  | Should Be 2
        $j.docs[0].name   | Should Be 'SPEC'
        $j.docs[1].name   | Should Be 'HANDOVER'
    }

    It 'dedups by path, the incoming entry winning so a re-link can rename' {
        $existing = [pscustomobject]@{ id='x'; label='j'; branch='b'; repo='example-repo'; status='Review'; note=''; docs=@([pscustomobject]@{ name='old name'; path='C:\d\a.md'; type='md' }) }
        $body = [pscustomobject]@{ id='x'; docsAppend=@([pscustomobject]@{ name='new name'; path='C:\d\a.md'; type='md' }) }
        $j = Merge-JobUpsert -Job $body -Existing $existing -NextNum 2
        @($j.docs).Count  | Should Be 1
        $j.docs[0].name   | Should Be 'new name'
    }

    It 'seeds docs on create when only docsAppend is given' {
        $body = [pscustomobject]@{ label='new job'; docsAppend=@([pscustomobject]@{ name='SPEC'; path='C:\d\spec.md'; type='md' }) }
        $j = Merge-JobUpsert -Job $body -Existing $null -NextNum 1
        @($j.docs).Count  | Should Be 1
        $j.docs[0].name   | Should Be 'SPEC'
    }
}
