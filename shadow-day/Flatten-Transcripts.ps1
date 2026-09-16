<#
.SYNOPSIS
Flattens Claude Code transcripts into one markdown file per calendar day (Pacific/Auckland).

.DESCRIPTION
Reads the JSONL session logs under ~/.claude/projects for the chosen project folders and keeps
only the human-visible signal: Gerhard's prompts, the skills and agents he invoked, and a tally
of tools (including MCP connectors) each session touched. Tool results, assistant replies and
thinking are dropped, and subagent side-chains are excluded, so a day-file reflects what he
asked for, not what the model did. Output is what the classifier agents read instead of the raw
logs, which are roughly 97% tool output.

.PARAMETER Projects
Project folder name prefixes under ~/.claude/projects to include.

.PARAMETER OutDir
Where the YYYY-MM-DD.md day-files land. Existing files are overwritten.

.PARAMETER MaxPromptChars
Prompts longer than this (pasted blobs) are truncated with a marker.
#>
[CmdletBinding()]
param(
    [string[]]$Projects = @('C--Repos-Kupe', 'C--Repos-Personal-jobs', 'C--Repos-Bridge', 'C--Repos'),
    [string]$OutDir = 'C:\Repos\Personal\jobs\docs\183-shadow-day\days',
    [int]$MaxPromptChars = 1500,
    [datetime]$Since = '2026-01-01'
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $HOME '.claude\projects'
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('New Zealand Standard Time')
New-Item -ItemType Directory -Force $OutDir | Out-Null

$files = Get-ChildItem $root -Directory | Where-Object {
    $name = $_.Name
    # Exact match, or a worktree child such as C--Repos-Kupe--claude-worktrees-x; never a sibling repo.
    $Projects | Where-Object { $name -eq $_ -or $name.StartsWith("$_--") }
} | Get-ChildItem -Filter '*.jsonl' | Where-Object { $_.LastWriteTime -ge $Since }

Write-Host "[..] $($files.Count) transcript files, $([math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB)) MB"

# sessionId -> @{ title; cwd; branch; project; entries = List; tools = Hashtable }
$sessions = @{}

function Get-Text($content) {
    if ($content.ValueKind -eq 'String') { return $content.GetString() }
    if ($content.ValueKind -ne 'Array') { return '' }
    $parts = foreach ($b in $content.EnumerateArray()) {
        $t = Prop $b 'type'
        if ($t -and $t.GetString() -eq 'text') { (Prop $b 'text').GetString() }
    }
    return ($parts -join "`n")
}

function Prop($el, $name) {
    if ($el.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    [System.Text.Json.JsonElement]$v = [System.Text.Json.JsonElement]::new()
    if ($el.TryGetProperty([string]$name, [ref]$v)) { return $v }
    return $null
}

$lineCount = 0
foreach ($f in $files) {
    $project = $f.Directory.Name
    $reader = [System.IO.StreamReader]::new($f.FullName)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineCount++
            if ($line.Length -lt 20) { continue }
            # Cheap prefilter before JSON parsing: only user prompts, assistant tool calls and session titles matter.
            $isUser = $line.Contains('"type":"user"')
            $isAssistant = $line.Contains('"type":"assistant"') -and $line.Contains('"tool_use"')
            $isTitle = $line.Contains('"type":"ai-title"')
            if (-not ($isUser -or $isAssistant -or $isTitle)) { continue }
            if ($isUser -and $line.Contains('"tool_result"')) { continue }

            try { $doc = [System.Text.Json.JsonDocument]::Parse($line) } catch { continue }
            try {
                $o = $doc.RootElement
                $sid = (Prop $o 'sessionId')
                if (-not $sid) { continue }
                $sid = $sid.GetString()
                if (-not $sessions.ContainsKey($sid)) {
                    $sessions[$sid] = @{ title = ''; cwd = ''; branch = ''; project = $project; entries = [System.Collections.Generic.List[object]]::new(); tools = @{} }
                }
                $s = $sessions[$sid]

                if ($isTitle) { $t = Prop $o 'aiTitle'; if ($t) { $s.title = $t.GetString() }; continue }

                $side = Prop $o 'isSidechain'
                if ($side -and $side.GetBoolean()) { continue }

                $ts = Prop $o 'timestamp'
                if (-not $ts) { continue }
                $utc = [datetime]::Parse($ts.GetString(), $null, 'AdjustToUniversal')
                $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
                $cwd = Prop $o 'cwd'; if ($cwd -and -not $s.cwd) { $s.cwd = $cwd.GetString() }
                $br = Prop $o 'gitBranch'; if ($br -and -not $s.branch) { $s.branch = $br.GetString() }

                $msg = Prop $o 'message'
                if (-not $msg) { continue }
                $content = Prop $msg 'content'
                if (-not $content) { continue }

                if ($isUser) {
                    $meta = Prop $o 'isMeta'
                    if ($meta -and $meta.GetBoolean()) { continue }
                    $text = (Get-Text $content).Trim()
                    if (-not $text) { continue }
                    # Slash-command invocations arrive wrapped in <command-name>; keep the name and args only.
                    if ($text -match '<command-name>([^<]+)</command-name>') {
                        $cmd = $Matches[1]
                        $args = if ($text -match '<command-args>([^<]*)</command-args>') { $Matches[1] } else { '' }
                        $s.entries.Add([pscustomobject]@{ t = $local; kind = 'skill'; text = "$cmd $args".Trim() })
                        continue
                    }
                    if ($text.StartsWith('<') -and $text -notmatch '^<[a-z-]+>\s*\S') { continue }
                    if ($text.Length -gt $MaxPromptChars) { $text = $text.Substring(0, $MaxPromptChars) + " [... truncated, $($text.Length) chars]" }
                    $s.entries.Add([pscustomobject]@{ t = $local; kind = 'user'; text = $text })
                }
                elseif ($content.ValueKind -eq 'Array') {
                    foreach ($b in $content.EnumerateArray()) {
                        if ((Prop $b 'type').GetString() -ne 'tool_use') { continue }
                        $name = (Prop $b 'name').GetString()
                        $s.tools[$name] = 1 + [int]$s.tools[$name]
                        $inp = Prop $b 'input'
                        switch ($name) {
                            'Skill' { $s.entries.Add([pscustomobject]@{ t = $local; kind = 'skill'; text = "$((Prop $inp 'skill').GetString()) $(if ($a = Prop $inp 'args') { $a.GetString() })".Trim() }) }
                            'Agent' { $s.entries.Add([pscustomobject]@{ t = $local; kind = 'agent'; text = "$(if ($x = Prop $inp 'subagent_type') { $x.GetString() }) / $(if ($x = Prop $inp 'model') { $x.GetString() }): $(if ($x = Prop $inp 'description') { $x.GetString() })" }) }
                            'Workflow' { $s.entries.Add([pscustomobject]@{ t = $local; kind = 'workflow'; text = 'workflow run' }) }
                        }
                    }
                }
            } finally { $doc.Dispose() }
        }
    } finally { $reader.Dispose() }
}

Write-Host "[..] $lineCount lines scanned, $($sessions.Count) sessions"

# Group session entries by local calendar day; a session spanning midnight lands in each day it touched.
$days = @{}
foreach ($kv in $sessions.GetEnumerator()) {
    $s = $kv.Value
    if ($s.entries.Count -eq 0) { continue }
    foreach ($g in ($s.entries | Group-Object { $_.t.ToString('yyyy-MM-dd') })) {
        if (-not $days.ContainsKey($g.Name)) { $days[$g.Name] = [System.Collections.Generic.List[object]]::new() }
        $days[$g.Name].Add([pscustomobject]@{ sid = $kv.Key; s = $s; entries = ($g.Group | Sort-Object t) })
    }
}

Get-ChildItem $OutDir -Filter '*.md' | Remove-Item
foreach ($day in ($days.Keys | Sort-Object)) {
    $blocks = $days[$day] | Sort-Object { $_.entries[0].t }
    $prompts = ($blocks | ForEach-Object { ($_.entries | Where-Object kind -eq 'user').Count } | Measure-Object -Sum).Sum
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $day ($(([datetime]$day).DayOfWeek))")
    [void]$sb.AppendLine("Sessions: $($blocks.Count) | Prompts: $prompts")
    [void]$sb.AppendLine()
    foreach ($b in $blocks) {
        $s = $b.s
        $first = $b.entries[0].t.ToString('HH:mm'); $last = $b.entries[-1].t.ToString('HH:mm')
        [void]$sb.AppendLine("## $first-$last  $($s.title)")
        [void]$sb.AppendLine("project: $($s.project) | cwd: $($s.cwd) | branch: $($s.branch) | session: $($b.sid.Substring(0,8))")
        $toolLine = ($s.tools.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        [void]$sb.AppendLine("tools (whole session): $toolLine")
        [void]$sb.AppendLine()
        foreach ($e in $b.entries) {
            $text = $e.text -replace "`r?`n", "`n    "
            [void]$sb.AppendLine("- $($e.t.ToString('HH:mm')) [$($e.kind)] $text")
        }
        [void]$sb.AppendLine()
    }
    [System.IO.File]::WriteAllText((Join-Path $OutDir "$day.md"), $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

$total = ($days.Values | ForEach-Object { $_ } | ForEach-Object { ($_.entries | Where-Object kind -eq 'user').Count } | Measure-Object -Sum).Sum
Write-Host "[OK] $($days.Count) day-files, $total prompts -> $OutDir"
