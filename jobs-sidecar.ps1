<#
.SYNOPSIS
  Jobs sidecar — thin PS7 HttpListener server for the promoted Jobs app.

  Routes:
    GET  /                         -> jobs.html (rail + kanban + detail + ADO Assigned mode)
    GET  /health                   -> {ok:true}
    GET  /config                   -> jobs.config.json (+ local override merge)
    GET  /jobs                     -> read jobs.json (the rich board)
    POST /jobs                     -> upsert a job ({label,branch?,repo?,status?,note?,docs?,pr?,id?})
    DELETE /jobs/{id}               -> delete a job
    GET  /ado/assigned             -> my current-sprint ADO work; az-backed, cached ~120s;
                                       ?refresh=1 bypass, ?demo=1 fixture
    GET  /git/branch?repo=KEY      -> current branch of that repo's main checkout
    GET  /git/branches?repo=KEY    -> local branches (recent first) for the add-job picker
    GET  /git/log?repo=KEY&branch=NAME -> up to 15 commits (merge-base..branch), each with files
    POST /open                     -> open a linked .html doc in the host's default browser
    GET  /poll/{script}            -> read {script}.latest.json (phase, pct, done, status) —
                                       a generic status-file reader
    GET  /briefs/{path}            -> static files from ~/.claude/scheduled-prompts/briefs/
                                       (factory briefs + screenshot PNGs); /briefs/latest.html
                                       always resolves to the newest *-morning-brief.html
    GET  /almanac/{path}           -> static files from ~/.claude/almanac/ (the morning
                                       read); /almanac/latest.html always resolves to the
                                       newest *-almanac.html

  A background PR-status sweep also runs invisibly off the main request loop (no route, no
  button): on the configured cadence (prCheck.intervalSec), it checks each PR-status job's
  linked pr and flips it to Done/Parked when the ADO PR merges/is abandoned. See
  check-pr-status.ps1.

  Invoke: pwsh -NoProfile -File jobs-sidecar.ps1 [-Port 7799]
#>
#Requires -Version 7

param([int]$Port = 7799)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ConfigPath = Join-Path $ScriptRoot 'jobs.config.json'
$LocalConfigPath = Join-Path $ScriptRoot 'jobs.config.local.json'

# Config loading (base + optional per-machine override). Dot-sourced so the merge
# logic is shared with the tests and $ConfigPath/$LocalConfigPath above are in scope.
. (Join-Path $ScriptRoot 'config-layering.ps1')

$JobsPath     = Join-Path $ScriptRoot 'jobs.json'          # rich board data store
$HtmlPath     = Join-Path $ScriptRoot 'jobs.html'
$BriefsDir    = Join-Path $env:USERPROFILE '.claude\scheduled-prompts\briefs'
# The Almanac pages live outside the Almanac repo on purpose: they are per-day
# artefacts carrying personal content, and the repo is machinery. Same split as
# birth data in the Astrology repo.
$AlmanacDir   = Join-Path $env:USERPROFILE '.claude\almanac'

# --- shared helpers ------------------------------------------------------------

function Send-Json {
    param($Ctx, $Obj, [int]$Code = 200)
    $json  = $Obj | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Ctx.Response.StatusCode      = $Code
    $Ctx.Response.ContentType     = 'application/json; charset=utf-8'
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.AddHeader('Access-Control-Allow-Origin', '*')
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

function Send-Err { param($Ctx, [string]$Msg, [int]$Code = 400); Send-Json $Ctx @{error=$Msg} $Code }

function Send-File { param($Ctx, [string]$Path, [string]$ContentType)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Ctx.Response.StatusCode      = 200
    $Ctx.Response.ContentType     = $ContentType
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

function Read-BodyJson {
    param($Ctx)
    $raw = (New-Object System.IO.StreamReader $Ctx.Request.InputStream).ReadToEnd()
    if ($raw) { $raw | ConvertFrom-Json } else { $null }
}

function Get-Prop {
    # Safe property access for ConvertFrom-Json objects under StrictMode.
    param($Obj, [string]$Name, $Default = '')
    if (-not $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { $p.Value } else { $Default }
}

function Get-StateDir { Join-Path $env:TEMP 'jobs' }   # cache + status files live under TEMP

function Read-LatestJson {
    param([string]$ScriptName)
    $path = Join-Path (Get-StateDir) "$ScriptName.latest.json"
    if (-not (Test-Path $path)) { return $null }
    try { Get-Content $path -Raw | ConvertFrom-Json } catch { $null }
}

# --- rich board: /jobs CRUD (jobs.json) ---------------------------------------

function Read-Jobs {
    if (-not (Test-Path $JobsPath)) { return [pscustomobject]@{jobs=@()} }
    Get-Content $JobsPath -Raw | ConvertFrom-Json
}

function Save-Jobs { param($Data); $Data | ConvertTo-Json -Depth 5 | Set-Content $JobsPath -Encoding utf8 }

function New-JobId { [System.Guid]::NewGuid().ToString('N').Substring(0,8) }

function Repair-JobNums {
    # One-time migration: assign sequential nums to jobs that pre-date this field.
    # Sorts unnumbered jobs by createdAt (ISO 8601 sorts lexicographically).
    $data = Read-Jobs
    $unnumbered = @($data.jobs | Where-Object { -not $_.PSObject.Properties['num'] -or $null -eq $_.num })
    if (-not $unnumbered.Count) { return }
    $maxNum = ($data.jobs | ForEach-Object {
        $p = $_.PSObject.Properties['num']; if ($p -and $null -ne $p.Value) { [int]$p.Value } else { 0 }
    } | Measure-Object -Maximum).Maximum
    foreach ($j in ($unnumbered | Sort-Object { $_.createdAt })) {
        $maxNum++
        $j | Add-Member -NotePropertyName num -NotePropertyValue $maxNum -Force
    }
    Save-Jobs $data
}

function Repair-JobUpdatedAt {
    # One-time migration: seed updatedAt from createdAt for jobs that pre-date the
    # field. From here on the upsert stamps it on every write.
    $data = Read-Jobs
    $stale = @($data.jobs | Where-Object { -not $_.PSObject.Properties['updatedAt'] -or -not $_.updatedAt })
    if (-not $stale.Count) { return }
    foreach ($j in $stale) {
        $j | Add-Member -NotePropertyName updatedAt -NotePropertyValue $j.createdAt -Force
    }
    Save-Jobs $data
}

function Get-NextJobNum {
    # Pure: the num to stamp on the next created job. Monotonic — the stored nextNum acts
    # as a floor so deleting the highest job doesn't hand its number to the next create,
    # which would silently repoint any "#N" cross-reference sitting in a note. Falls back
    # to max+1 on a board written before the field existed, so it self-heals on first write.
    param($Data)
    $maxNum = ($Data.jobs | ForEach-Object {
        $p = $_.PSObject.Properties['num']; if ($p -and $null -ne $p.Value) { [int]$p.Value } else { 0 }
    } | Measure-Object -Maximum).Maximum
    [Math]::Max([int](Get-Prop $Data 'nextNum' 0), [int]$maxNum + 1)
}

function Test-KnownRepo {
    # Pure: is $Key present in the config's repos map? An empty key means "no repo pinned",
    # which is legitimate, so it passes. No I/O, so it's testable without a config file.
    param([string]$Key, $Repos)
    if (-not $Key) { return $true }
    [bool]($Repos -and $Repos.PSObject.Properties[$Key])
}

function Merge-JobUpsert {
    # Pure: computes the job to persist for a POST /jobs body. $Existing -> update (mutated
    # in place, field-by-field, an omitted field falling back to its current value); $null ->
    # create (a fresh job, $NextNum stamped as its sequential num). No I/O, so it's testable
    # without an HttpListenerContext.
    param($Job, $Existing, [int] $NextNum)
    if ($Existing) {
        $Existing.label  = Get-Prop $Job 'label' $Existing.label
        $Existing.branch = Get-Prop $Job 'branch' $Existing.branch
        if ($Existing.PSObject.Properties['repo']) { $Existing.repo = Get-Prop $Job 'repo' $Existing.repo }
        else { $Existing | Add-Member -NotePropertyName repo -NotePropertyValue (Get-Prop $Job 'repo') }
        if ($Existing.PSObject.Properties['pr']) { $Existing.pr = Get-Prop $Job 'pr' $Existing.pr }
        else { $Existing | Add-Member -NotePropertyName pr -NotePropertyValue (Get-Prop $Job 'pr') }
        $Existing.status = Get-Prop $Job 'status' $Existing.status
        $Existing.note   = Get-Prop $Job 'note'   $Existing.note
        $Existing.docs   = @(@(Get-Prop $Job 'docs'   (Get-Prop $Existing 'docs' @())) | Where-Object { $_ -ne $null })
        $Existing | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date -Format 'o') -Force
        return $Existing
    }
    return [pscustomobject]@{
        id        = New-JobId
        num       = $NextNum
        label     = Get-Prop $Job 'label'
        branch    = Get-Prop $Job 'branch'
        repo      = Get-Prop $Job 'repo'
        pr        = Get-Prop $Job 'pr'
        status    = Get-Prop $Job 'status' 'Planned'
        note      = Get-Prop $Job 'note'
        docs      = @(@(Get-Prop $Job 'docs' @()) | Where-Object { $_ -ne $null })
        createdAt = (Get-Date -Format 'o')
        updatedAt = (Get-Date -Format 'o')
    }
}

function Handle-GetJobs { param($Ctx); Send-Json $Ctx (Read-Jobs) }

function Handle-PostJob { param($Ctx)
    $job = Read-BodyJson $Ctx
    if (-not $job) { Send-Err $Ctx 'body required'; return }

    # A repo key missing from config.repos costs nothing at write time and then renders as
    # "unknown repo" in the commit graph much later, far from the typo. Reject it here and
    # name the valid keys, so the error is self-correcting. Only checked when the body
    # actually carries a repo — an update that omits it keeps whatever the job already had,
    # which may legitimately name a repo this machine's config doesn't know.
    $repoKey = Get-Prop $job 'repo'
    $repos   = Get-Prop (Get-JobsConfig) 'repos' $null
    if (-not (Test-KnownRepo $repoKey $repos)) {
        $valid = (($repos.PSObject.Properties.Name | Sort-Object) -join ', ')
        Send-Err $Ctx "unknown repo key '$repoKey' - valid keys: $valid"; return
    }

    $data = Read-Jobs
    $jobs = [System.Collections.Generic.List[object]] @($data.jobs)

    $jobId    = Get-Prop $job 'id'
    $existing = $jobs | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
    if (-not $existing -and -not (Get-Prop $job 'label')) { Send-Err $Ctx 'label required for new jobs'; return }

    $next     = Get-NextJobNum $data
    $upserted = Merge-JobUpsert -Job $job -Existing $existing -NextNum $next
    if (-not $existing) {
        $jobs.Add($upserted)
        $data | Add-Member -NotePropertyName nextNum -NotePropertyValue ($next + 1) -Force
    }

    $data.jobs = $jobs.ToArray()
    Save-Jobs $data
    Send-Json $Ctx $upserted
}

function Handle-DeleteJob { param($Ctx, [string]$Id)
    $data = Read-Jobs
    $data.jobs = @($data.jobs | Where-Object { $_.id -ne $Id })
    Save-Jobs $data
    Send-Json $Ctx $data
}

# --- /config -------------------------------------------------------------------

function Handle-GetConfig { param($Ctx)
    $cfg = Get-JobsConfig
    Send-Json $Ctx $cfg
}

# --- git graph -------------------------------------------------------------------
# Jobs pin a repo KEY; we resolve path + trunk from config.repos and shell out to
# git. Worktrees are a non-issue: a branch checked out in a worktree still lives in
# the main repo's ref store, so `git -C <root> log <branch>` reads it fine.

function Resolve-Repo {
    param([string]$Key)
    if (-not $Key) { return $null }
    $cfg   = Get-JobsConfig
    $repos = Get-Prop $cfg 'repos' $null
    if (-not $repos) { return $null }
    $entry = $repos.PSObject.Properties[$Key]
    if ($entry) { $entry.Value } else { $null }
}

function Invoke-Git {
    # Returns {ok,out[]}. Non-zero exit (e.g. an intentional rev-parse --verify miss)
    # is data, not an error — try/catch absorbs PSNativeCommand error-action quirks.
    # git writes UTF-8, but PowerShell decodes native stdout via [Console]::OutputEncoding
    # (an OEM codepage by default on Windows) — em dashes in commit messages come out as
    # mojibake. Force UTF-8 for the call, restore after.
    param([string]$Path, [string[]]$GitArgs)
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $out = & git -C $Path @GitArgs 2>$null
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); out = @($out) }
    } catch {
        [pscustomobject]@{ ok = $false; out = @() }
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
}

function Handle-GitBranch { param($Ctx)
    $key  = $Ctx.Request.QueryString['repo']
    $repo = Resolve-Repo $key
    if (-not $repo) { Send-Err $Ctx "unknown repo: $key" 404; return }
    $r = Invoke-Git $repo.path @('rev-parse','--abbrev-ref','HEAD')
    if (-not $r.ok) { Send-Json $Ctx @{repo=$key; branch=$null; error='not a git repo'}; return }
    Send-Json $Ctx @{repo=$key; branch=($r.out | Select-Object -First 1)}
}

function Handle-GitBranches { param($Ctx)
    $key  = $Ctx.Request.QueryString['repo']
    $repo = Resolve-Repo $key
    if (-not $repo) { Send-Err $Ctx "unknown repo: $key" 404; return }
    $r = Invoke-Git $repo.path @('branch','--format=%(refname:short)','--sort=-committerdate')
    $branches = if ($r.ok) { @($r.out | Where-Object { $_ }) } else { @() }
    Send-Json $Ctx @{repo=$key; branches=$branches}
}

function Handle-GitLog { param($Ctx)
    $key    = $Ctx.Request.QueryString['repo']
    $branch = $Ctx.Request.QueryString['branch']
    $repo   = Resolve-Repo $key
    if (-not $repo)    { Send-Err $Ctx "unknown repo: $key" 404; return }
    if (-not $branch)  { Send-Err $Ctx 'branch required'; return }

    $path  = $repo.path
    $trunk = Get-Prop $repo 'trunk' 'master'

    $chk = Invoke-Git $path @('rev-parse','--verify','--quiet', "$branch^{commit}")
    if (-not $chk.ok) { Send-Json $Ctx @{repo=$key; branch=$branch; commits=@(); error='branch not found'}; return }

    # Feature branch -> show only its own commits (merge-base..branch). Trunk, or a
    # branch with no shared base, falls back to its last 15 commits. Always capped at 15.
    $range = $branch
    if ($branch -ne $trunk) {
        $mb = Invoke-Git $path @('merge-base', $trunk, $branch)
        $base = if ($mb.ok) { ($mb.out | Select-Object -First 1) } else { $null }
        if ($base) { $range = "$($base.Trim())..$branch" }
    }

    $US = [char]0x1f; $RS = [char]0x1e
    $fmt  = "%H$US%h$US%an$US%ar$US%s$US%b$RS"
    $meta = Invoke-Git $path @('log', $range, '-n', '15', "--format=$fmt")
    if (-not $meta.ok) {
        $range = $branch
        $meta  = Invoke-Git $path @('log', $range, '-n', '15', "--format=$fmt")
    }

    # File lists in one call: %x1e<hash> then the commit's name-status lines.
    $files = @{}
    $fr = Invoke-Git $path @('log', $range, '-n', '15', '--name-status', "--format=$RS%H")
    if ($fr.ok) {
        foreach ($chunk in (($fr.out -join "`n") -split [string]$RS)) {
            $lines = @($chunk -split "`n" | Where-Object { $_ -ne '' })
            if ($lines.Count -lt 1) { continue }
            $hash = $lines[0].Trim()
            $fl = @()
            if ($lines.Count -gt 1) {
                foreach ($ln in $lines[1..($lines.Count-1)]) {
                    if ($ln -match '^(\S+)\t(.+)$') { $fl += [pscustomobject]@{ status=$Matches[1]; path=$Matches[2] } }
                }
            }
            $files[$hash] = $fl
        }
    }

    $commits = @()
    foreach ($rec in (($meta.out -join "`n") -split [string]$RS)) {
        if (-not $rec.Trim()) { continue }
        $parts = $rec -split [string]$US
        if ($parts.Count -lt 6) { continue }
        $hash = $parts[0].Trim()
        $commits += [pscustomobject]@{
            hash    = $hash
            short   = $parts[1]
            author  = $parts[2]
            relDate = $parts[3]
            subject = $parts[4]
            body    = $parts[5].Trim()
            files   = @($files[$hash])
        }
    }

    Send-Json $Ctx @{repo=$key; branch=$branch; trunk=$trunk; range=$range; commits=$commits}
}

function Handle-OpenDoc { param($Ctx)
    # Open a linked job document in the host's default browser. The detail card only
    # routes LOCAL .html here (URLs and editor files it opens itself), so we allowlist
    # html/htm and Start-Process the file — no file bytes over the wire.
    $body = Read-BodyJson $Ctx
    $p = if ($body) { [string]$body.path } else { $null }
    if (-not $p) { Send-Err $Ctx 'path required'; return }
    if ($p -notmatch '\.html?$') { Send-Err $Ctx 'only .html/.htm can be opened in the browser' 400; return }
    if (-not (Test-Path -LiteralPath $p)) { Send-Err $Ctx "file not found: $p" 404; return }
    Start-Process -FilePath $p
    Send-Json $Ctx @{opened = $true; path = $p}
}

# --- dated-artefact static routes ------------------------------------------------
# Serves folders of dated HTML pages (plus their images) over the same localhost +
# Tailscale route as everything else, each with a `latest.html` that always resolves to
# the newest page so nothing has to be edited per run. Two consumers today:
#   /briefs/   -> ~/.claude/scheduled-prompts/briefs/  (the factory brief + screenshots)
#   /almanac/  -> ~/.claude/almanac/                   (the morning read)
# Path-traversal guarded since this port can be Tailscale-exposed.
#
# One resolver, parametrised by the newest-file glob, rather than a copy per consumer:
# the traversal guard below is the security boundary for anything served here, and a
# second copy of it is a second thing to get right.

# Takes a list of globs, not one, so a renamed artefact doesn't orphan its history:
# the factory brief used to be written as *-morning-brief.html and every existing one
# still is. Matching both keeps latest.html resolving across the rename.
function Get-LatestFile {
    param([string]$Dir, [string[]]$Patterns)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    $found = foreach ($pattern in $Patterns) {
        Get-ChildItem -LiteralPath $Dir -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    $found | Sort-Object Name -Descending | Select-Object -First 1
}

# Maps a requested <subpath> onto a real file under $Root, or returns $null if it
# doesn't resolve to one (missing file, empty folder, or an escape attempt like
# '../jobs.config.local.json' trying to resolve outside the served folder).
function Resolve-StaticFile {
    param([string]$Root, [string]$RequestedPath, [string[]]$LatestPattern)

    if ([string]::IsNullOrWhiteSpace($RequestedPath) -or $RequestedPath -eq 'latest.html') {
        $latest = Get-LatestFile -Dir $Root -Patterns $LatestPattern
        return $(if ($latest) { $latest.FullName } else { $null })
    }

    $decoded = [System.Uri]::UnescapeDataString($RequestedPath)
    if ($decoded -match '\.\.') { return $null }  # reject outright; belt-and-braces on top of the resolve check below

    $base = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $decoded))
    if ($full -ne $base -and -not $full.StartsWith($base + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    return $full
}

function Get-StaticContentType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.svg'  { 'image/svg+xml' }
        default { 'application/octet-stream' }
    }
}

function Handle-GetStatic {
    param($Ctx, [string]$RequestedPath, [string]$Root, [string[]]$LatestPattern, [string]$Label)
    $file = Resolve-StaticFile -Root $Root -RequestedPath $RequestedPath -LatestPattern $LatestPattern
    if (-not $file) { Send-Err $Ctx "$Label not found: $RequestedPath" 404; return }
    Send-File $Ctx $file (Get-StaticContentType $file)
}

function Handle-GetBrief {
    param($Ctx, [string]$RequestedPath, [string]$BriefsDir)
    Handle-GetStatic $Ctx $RequestedPath $BriefsDir @('*-factory-brief.html', '*-morning-brief.html') 'brief'
}

function Handle-GetAlmanac {
    param($Ctx, [string]$RequestedPath, [string]$AlmanacDir)
    Handle-GetStatic $Ctx $RequestedPath $AlmanacDir @('*-almanac.html') 'almanac'
}

# --- ADO assigned rail -------------------------------------------------------
# Jobs panel "Assigned (ADO)" mode shows my current-sprint Azure DevOps work: Stories
# (Product Backlog Items) with the Tasks assigned to me nested under them. We shell out to
# `az` (same pattern as Invoke-Git), inheriting the signed-in user's cached creds — no auth
# wiring, az stays on the machine, never the browser.

function Invoke-Az {
    # Returns {ok,out,err}. `out` is raw stdout; `err` is stderr (string).
    # az writes a cp1252 encoding warning to stderr for unicode titles — force UTF-8 so titles
    # aren't mangled, but we capture stderr rather than discard it so auth/token errors surface.
    # Non-zero exit -> ok:$false (e.g. not logged in, token expired).
    param([string[]]$AzArgs)
    $prev = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = 'utf-8'
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & az @AzArgs 2>$errFile
        $exitCode = $LASTEXITCODE
        $err = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) ?? ''
        # Strip the benign cp1252 encoding advisory so it doesn't pollute real errors.
        $err = ($err -replace '(?m)^.*WARNING: The default encoding.*\r?\n?', '').Trim()
        [pscustomobject]@{ ok = ($exitCode -eq 0); out = $out; err = $err }
    } catch {
        [pscustomobject]@{ ok = $false; out = $null; err = $_.Exception.Message }
    } finally {
        $env:PYTHONIOENCODING = $prev
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
}

function Invoke-AzJson {
    param([string[]]$AzArgs)
    $r = Invoke-Az ($AzArgs + @('-o', 'json'))
    if (-not $r.ok) { return $null }
    try { ($r.out -join "`n") | ConvertFrom-Json } catch { $null }
}

function ConvertTo-PlainText {
    # ADO Description/Acceptance Criteria come back as HTML on legacy items and as plain
    # markdown on items authored in the newer editor. Strip tags + decode entities so HTML
    # collapses to readable text; markdown/plain text passes through untouched (no tags to
    # strip). Dumb and dependency-free by design. The frontend still HTML-escapes before it
    # hits the DOM, so this is about readability, not safety.
    param([string]$Html)
    if (-not $Html) { return '' }
    $t = $Html
    $t = $t -replace '(?i)<br\s*/?>', "`n"
    $t = $t -replace '(?i)</(p|div|li|tr|h[1-6])\s*>', "`n"
    $t = $t -replace '(?i)<li[^>]*>', '- '
    $t = $t -replace '<[^>]+>', ''                 # strip every remaining tag
    $t = $t -replace '&nbsp;', ' '
    $t = $t -replace '&amp;', '&'
    $t = $t -replace '&lt;', '<'
    $t = $t -replace '&gt;', '>'
    $t = $t -replace '&quot;', '"'
    $t = $t -replace '&#39;', "'"
    $t = $t -replace '&apos;', "'"
    $t = $t -replace '[ \t]+\n', "`n"              # trailing spaces per line
    $t = $t -replace '\n{3,}', "`n`n"              # collapse blank-line runs
    $t.Trim()
}

function Get-WiField {
    # Safe access to a work item's fields.<ref> under StrictMode (fields are sparse).
    param($Item, [string]$Ref, $Default = $null)
    if (-not $Item) { return $Default }
    $f = $Item.PSObject.Properties['fields']
    if (-not $f) { return $Default }
    $p = $f.Value.PSObject.Properties[$Ref]
    if ($p -and $null -ne $p.Value) { $p.Value } else { $Default }
}

function ConvertTo-AdoTasks {
    # Pure: split my sprint tasks into open (To Do / In Progress) + a Done count. Unit-testable.
    param($TaskItems)
    $open = [System.Collections.Generic.List[object]]::new()
    $done = 0
    foreach ($t in @($TaskItems)) {
        $state = [string](Get-WiField $t 'System.State')
        if ($state -eq 'Done') { $done++; continue }
        if ($state -eq 'To Do' -or $state -eq 'In Progress') {
            $open.Add([pscustomobject]@{
                id          = Get-WiField $t 'System.Id'
                title       = Get-WiField $t 'System.Title'
                state       = $state
                parent      = Get-WiField $t 'System.Parent'
                description = ConvertTo-PlainText ([string](Get-WiField $t 'System.Description'))
            })
        }
    }
    [pscustomobject]@{ open = @($open); done = $done }
}

function ConvertTo-AdoStories {
    # Pure shaping: keep stories in {In Progress, Ready} that still have >=1 of my open tasks;
    # sort stories by sprint order (BacklogPriority asc — the drag-rank shared by the product
    # and sprint backlogs), then id; nest tasks (In Progress before To Do); build ADO urls.
    # Unit-testable — no az calls, no HTTP.
    param($OpenTasks, $StoryItems, [string]$WorkItemUrl)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($StoryItems)) {
        $pstate = [string](Get-WiField $p 'System.State')
        if ($pstate -ne 'In Progress' -and $pstate -ne 'Ready') { continue }
        $storyId = Get-WiField $p 'System.Id'
        $kids = @($OpenTasks | Where-Object { $_.parent -eq $storyId })
        if ($kids.Count -eq 0) { continue }
        $kids = @($kids | Sort-Object @{ Expression = { if ($_.state -eq 'In Progress') { 0 } else { 1 } } }, id)
        $tagsRaw = [string](Get-WiField $p 'System.Tags')
        # [string[]] forces an array: PowerShell unwraps a single-element pipeline result to a
        # scalar on assignment, which would send the frontend a bare string for one-tag stories.
        [string[]]$tags = if ($tagsRaw) { @($tagsRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
        $ac = ConvertTo-PlainText ([string](Get-WiField $p 'Microsoft.VSTS.Common.AcceptanceCriteria'))
        # Sprint order = BacklogPriority asc. Items without a rank (shouldn't happen for a
        # backlogged story) sort last rather than crash the comparison.
        $bpRaw = Get-WiField $p 'Microsoft.VSTS.Common.BacklogPriority'
        $bp = if ($null -ne $bpRaw) { [double]$bpRaw } else { [double]::MaxValue }
        $out.Add([pscustomobject]@{
            id              = $storyId
            title           = Get-WiField $p 'System.Title'
            state           = $pstate
            backlogPriority = $bp
            tags            = $tags
            description     = ConvertTo-PlainText ([string](Get-WiField $p 'System.Description'))
            ac              = if ($ac) { $ac } else { $null }
            url             = "$WorkItemUrl$storyId"
            tasks           = @($kids | ForEach-Object {
                [pscustomobject]@{ id = $_.id; title = $_.title; state = $_.state; description = $_.description; url = "$WorkItemUrl$($_.id)" }
            })
        })
    }
    @($out | Sort-Object backlogPriority, id)
}

function Get-AdoIdentity {
    # Initials from the az signed-in UPN local part: first.last -> FL. No Graph call.
    $r = Invoke-Az @('account', 'show', '--query', 'user.name', '-o', 'tsv')
    $upn = if ($r.ok) { [string]($r.out | Select-Object -First 1) } else { $null }
    $initials = '?'
    if ($upn) {
        $local = ($upn -split '@')[0]
        $parts = @($local -split '[._-]' | Where-Object { $_ })
        if ($parts.Count -ge 2)      { $initials = ($parts[0].Substring(0,1) + $parts[1].Substring(0,1)).ToUpper() }
        elseif ($parts.Count -eq 1)  { $initials = $parts[0].Substring(0, [Math]::Min(2, $parts[0].Length)).ToUpper() }
    }
    [pscustomobject]@{ upn = $upn; initials = $initials }
}

function Get-AdoDemoFixture {
    # Static fixture behind ?demo=1 — exercises sprint-order sort, the Ready filter, and multi-task
    # nesting that the sparse live data can't. Never touches az; never pollutes the real cache.
    [ordered]@{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        iteration = 'Sprint DEMO'
        identity  = @{ upn = 'demo.user@example.com'; initials = 'DU' }
        counts    = @{ stories = 3; tasks = 5; done = 7 }
        stories   = @(
            [ordered]@{
                id = 50001; title = 'Validate form input on submit'; state = 'In Progress'; backlogPriority = 1001
                tags = @('frontend', 'validation'); description = "Check required fields against the schema on submit.`n`nInline errors should point at the offending field."; ac = "- Invalid input blocks submit`n- Error names the bad field"
                url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50001'
                tasks = @(
                    [ordered]@{ id = 50010; title = 'Validate each field on submit'; state = 'In Progress'; description = 'Check each value against the schema.'; url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50010' }
                    [ordered]@{ id = 50011; title = 'Inline validation errors in the form'; state = 'To Do'; description = 'Surface the first invalid field inline.'; url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50011' }
                )
            },
            [ordered]@{
                id = 50002; title = 'Reconcile nightly data export'; state = 'In Progress'; backlogPriority = 1002
                tags = @('backend'); description = 'Diff the exported records against the source and flag drift.'; ac = $null
                url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50002'
                tasks = @(
                    [ordered]@{ id = 50020; title = 'Diff export against source'; state = 'To Do'; description = 'Nightly batch comparison.'; url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50020' }
                    [ordered]@{ id = 50021; title = 'Report drift to the log'; state = 'To Do'; description = ''; url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50021' }
                )
            },
            [ordered]@{
                id = 50003; title = 'Add approval step to the transfer flow'; state = 'Ready'; backlogPriority = 1003
                tags = @('backend', 'internal-tech'); description = 'Route transfer requests through an approval step.'; ac = "- Transfer requires approval`n- Confirmation email sent"
                url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50003'
                tasks = @(
                    [ordered]@{ id = 50030; title = 'Wire the approval handoff'; state = 'To Do'; description = 'Route the request to the approver.'; url = 'https://dev.azure.com/your-org/YourProject/_workitems/edit/50030' }
                )
            }
        )
    }
}

function Send-StaleCacheOrError { param($Ctx, $CachePath, $ErrorMsg)
    # On az failure, serve stale cache rather than a hard error when we have prior data.
    if (Test-Path $CachePath) {
        try {
            $stale = Get-Content $CachePath -Raw | ConvertFrom-Json
            $stale | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
            $stale | Add-Member -NotePropertyName staleReason -NotePropertyValue $ErrorMsg -Force
            Send-Json $Ctx $stale
            return
        } catch { }
    }
    Send-Json $Ctx @{ error = $ErrorMsg; fetchedAt = (Get-Date).ToUniversalTime().ToString('o') }
}

function Handle-GetAdoAssigned { param($Ctx)
    $demo    = $Ctx.Request.QueryString['demo'] -eq '1'
    $refresh = $Ctx.Request.QueryString['refresh'] -eq '1'

    if ($demo) { Send-Json $Ctx (Get-AdoDemoFixture); return }

    $cachePath = Join-Path (Get-StateDir) 'jobs-ado-rail.json'
    if (-not $refresh -and (Test-Path $cachePath)) {
        $age = ([datetime]::UtcNow - (Get-Item $cachePath).LastWriteTimeUtc).TotalSeconds
        if ($age -lt 120) {
            try { Send-Json $Ctx (Get-Content $cachePath -Raw | ConvertFrom-Json); return } catch { }
        }
    }

    $cfg = Get-JobsConfig
    $ado = Get-Prop $cfg 'ado' $null
    $team        = if ($ado) { Get-Prop $ado 'currentSprintTeam' 'Your Team' } else { 'Your Team' }
    $project     = if ($ado) { Get-Prop $ado 'project' 'YourProject' } else { 'YourProject' }
    $workItemUrl = if ($ado) { Get-Prop $ado 'workItemUrl' 'https://dev.azure.com/your-org/YourProject/_workitems/edit/' } else { 'https://dev.azure.com/your-org/YourProject/_workitems/edit/' }
    # Pin the org from config — az's machine-default org can drift, which 404s
    # every call. Passing --org explicitly makes the app independent of that default.
    $org         = if ($ado) { Get-Prop $ado 'org' 'https://dev.azure.com/your-org' } else { 'https://dev.azure.com/your-org' }

    # Resolve the current sprint live so the feature keeps working next sprint.
    $iter = Invoke-Az @('boards', 'iteration', 'team', 'list', '--team', $team, '--project', $project, '--org', $org, '--timeframe', 'current', '--query', '[0].path', '-o', 'tsv')
    $iterPath = if ($iter.ok) { [string]($iter.out | Select-Object -First 1) } else { $null }
    if ($iterPath) { $iterPath = $iterPath.Trim() }
    if (-not $iterPath) {
        $detail = if ($iter.err) { " ($($iter.err))" } else { '' }
        Send-StaleCacheOrError $Ctx $cachePath "Could not resolve the current sprint — check ``az login``.$detail"
        return
    }
    $iterName = ($iterPath -split '\\')[-1]

    # Query 1 — my tasks this sprint (flat SELECT includes Description to avoid a third call).
    $wiqlTasks = "SELECT [System.Id],[System.Title],[System.State],[System.Parent],[System.Description] FROM WorkItems WHERE [System.AssignedTo]=@Me AND [System.IterationPath]='$iterPath' AND [System.WorkItemType]='Task'"
    $taskR = Invoke-Az (@('boards', 'query', '--wiql', $wiqlTasks, '--org', $org) + @('-o', 'json'))
    $taskItems = if ($taskR.ok) { try { ($taskR.out -join "`n") | ConvertFrom-Json } catch { $null } } else { $null }
    if ($null -eq $taskItems) {
        $detail = if ($taskR.err) { " ($($taskR.err))" } else { '' }
        Send-StaleCacheOrError $Ctx $cachePath "Could not query ADO work items — check ``az login``.$detail"
        return
    }

    $split = ConvertTo-AdoTasks $taskItems
    $parentIds = @($split.open | ForEach-Object { $_.parent } | Where-Object { $_ } | Select-Object -Unique)

    # Query 2 — the parent stories, by id, one call. Skip if no open tasks.
    $storyItems = @()
    if ($parentIds.Count -gt 0) {
        $idList = ($parentIds -join ',')
        $wiqlStories = "SELECT [System.Id],[System.Title],[System.State],[Microsoft.VSTS.Common.BacklogPriority],[System.Tags],[System.Description],[Microsoft.VSTS.Common.AcceptanceCriteria] FROM WorkItems WHERE [System.Id] IN ($idList)"
        $storyItems = Invoke-AzJson @('boards', 'query', '--wiql', $wiqlStories, '--org', $org)
    }

    $stories = ConvertTo-AdoStories $split.open $storyItems $workItemUrl
    $renderedTasks = ($stories | ForEach-Object { $_.tasks.Count } | Measure-Object -Sum).Sum
    if (-not $renderedTasks) { $renderedTasks = 0 }

    $identity = Get-AdoIdentity

    $payload = [ordered]@{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        iteration = $iterName
        identity  = @{ upn = $identity.upn; initials = $identity.initials }
        counts    = @{ stories = @($stories).Count; tasks = [int]$renderedTasks; done = [int]$split.done }
        stories   = @($stories)
    }

    $stateDir = Get-StateDir
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    try { $payload | ConvertTo-Json -Depth 10 | Set-Content $cachePath -Encoding utf8 } catch { }

    Send-Json $Ctx $payload
}

# --- background PR sweep -------------------------------------------------------------
# Fire check-pr-status.ps1 hidden, on a due-check cadence tracked by a guard file's mtime.

function Invoke-PrSweepIfDue {
    try {
        $cfg         = Get-JobsConfig
        $prCheck     = Get-Prop $cfg 'prCheck' $null
        $intervalSec = if ($prCheck) { Get-Prop $prCheck 'intervalSec' 3600 } else { 3600 }

        $stateDir  = Get-StateDir
        $guardPath = Join-Path $stateDir 'jobs-pr-sweep.last'
        if (Test-Path $guardPath) {
            $age = ([datetime]::UtcNow - (Get-Item $guardPath).LastWriteTimeUtc).TotalSeconds
            if ($age -lt $intervalSec) { return }
        }

        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        # Stamp the current time as the content, NOT an empty string — an unchanged mtime would
        # make the age check see the guard as perpetually stale and fire on every request.
        Set-Content -LiteralPath $guardPath -Value ([datetime]::UtcNow.ToString('o')) -NoNewline

        $data = Read-Jobs
        $hasPrJob = [bool]($data.jobs | Where-Object { $_.status -eq 'PR' -and $_.PSObject.Properties['pr'] -and $_.pr })
        if (-not $hasPrJob) { return }

        $scriptPath = Join-Path $ScriptRoot 'check-pr-status.ps1'
        $pwshExe    = [Environment]::ProcessPath   # this sidecar's own pwsh — guaranteed present, right version
        Start-Process $pwshExe -ArgumentList @('-NoProfile', '-File', $scriptPath) -WindowStyle Hidden
    } catch { }
}

# --- main loop ---------------------------------------------------------------
# Only stand up the listener when run as a script. Dot-sourcing (how the Pester tests
# load the pure helpers) sets InvocationName to '.' and skips this block.
if ($MyInvocation.InvocationName -ne '.') {

Repair-JobNums
Repair-JobUpdatedAt

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")
try {
    $listener.Start()
    Write-Host "Jobs sidecar on http://localhost:$Port (Ctrl+C to stop)"
} catch [System.Net.HttpListenerException] {
    if ($_.Exception.ErrorCode -ne 5) { throw }  # 5 = ERROR_ACCESS_DENIED; anything else fails loudly
    $listener.Close()
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    Write-Host "Jobs sidecar on http://localhost:$Port (local only — wildcard prefix unavailable)  (Ctrl+C to stop)"
}

try {
    while ($listener.IsListening) {
        $ctx    = $listener.GetContext()
        $method = $ctx.Request.HttpMethod
        $path   = $ctx.Request.Url.AbsolutePath.TrimEnd('/')

        Write-Host "$method $path"
        Invoke-PrSweepIfDue

        if ($method -eq 'OPTIONS') {
            $ctx.Response.AddHeader('Access-Control-Allow-Origin',  '*')
            $ctx.Response.AddHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
            $ctx.Response.AddHeader('Access-Control-Allow-Headers', 'Content-Type')
            $ctx.Response.StatusCode = 204
            $ctx.Response.Close()
            continue
        }

        try {
            switch -Regex ($path) {
                '^/?$'                    { Send-File $ctx $HtmlPath 'text/html; charset=utf-8'; break }
                '^/jobs-mark\.ico$'       { Send-File $ctx (Join-Path $ScriptRoot 'jobs-mark.ico') 'image/x-icon'; break }
                '^/apple-touch-icon\.png$' { Send-File $ctx (Join-Path $ScriptRoot 'apple-touch-icon.png') 'image/png'; break }
                '^/health$'               { Send-Json $ctx @{ok=$true}; break }
                '^/config$'               { Handle-GetConfig $ctx; break }
                '^/ado/assigned$'         { if ($method -eq 'GET') { Handle-GetAdoAssigned $ctx }; break }
                '^/jobs$' {
                    if ($method -eq 'GET')  { Handle-GetJobs $ctx }
                    elseif ($method -eq 'POST') { Handle-PostJob $ctx }
                    break
                }
                '^/jobs/([^/]+)$' {
                    if ($method -eq 'DELETE') { Handle-DeleteJob $ctx $Matches[1] }
                    break
                }
                '^/git/branch$'           { Handle-GitBranch $ctx; break }
                '^/git/branches$'         { Handle-GitBranches $ctx; break }
                '^/git/log$'              { Handle-GitLog $ctx; break }
                '^/open$'                 { if ($method -eq 'POST') { Handle-OpenDoc $ctx }; break }
                '^/briefs/?(.*)$'         { if ($method -eq 'GET') { Handle-GetBrief $ctx $Matches[1] $BriefsDir }; break }
                '^/almanac/?(.*)$'        { if ($method -eq 'GET') { Handle-GetAlmanac $ctx $Matches[1] $AlmanacDir }; break }
                '^/poll/([^/]+)$'        { $ctx | Out-Null; $latest = Read-LatestJson $Matches[1]; if ($latest) { Send-Json $ctx $latest } else { Send-Json $ctx @{done=$false; status=$null; phase='not-started'; script=$Matches[1]} }; break }
                default                   { Send-Err $ctx "not found: $path" 404 }
            }
        } catch {
            Write-Warning "Error handling $method $path : $_"
            try { Send-Err $ctx "internal error: $_" 500 } catch { }
        }
    }
} finally {
    $listener.Stop()
    Write-Host 'Jobs sidecar stopped.'
}

}  # end: run-as-script guard
