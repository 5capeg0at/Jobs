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
