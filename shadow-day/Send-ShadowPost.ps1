<#
.SYNOPSIS
Posts a shadow-day run to Gerhard's Slack DM as one short message with the detail threaded under it.

.DESCRIPTION
The top-level message is the run's headline section (the prompts write one, a few lines long), so
the DM reads at a glance. Under it, in the thread: each question as its own reply, so a reaction on
it is an answer (:+1: yes, :-1: no, :point_down: see his text reply), then every other section as
Slack mrkdwn. Slack has no tables, so the Compare table becomes bullets grouped by verdict, and any
other table becomes one bullet per row. The day file itself is untouched; the ledger still parses
the table from it.

.EXAMPLE
Send-ShadowPost.ps1 -Path C:\Users\me\AppData\Local\Temp\shadow-dm-2026-09-28.md -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Channel = 'UVBD1TSF8'   # Gerhard's Slack user id; a user id as channel opens the DM
)
$ErrorActionPreference = 'Stop'

function ConvertTo-Mrkdwn([string]$md, [switch]$KeepLines) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in ($md -split "`r?`n")) {
        $line = $raw.TrimEnd()
        # The prompts hard-wrap prose near 100 columns, which comes out ragged on a phone; a line
        # that isn't a bullet, heading, table row or blank continues the one before it.
        $continues = -not $KeepLines -and $line -and $lines.Count -and $lines[-1] -and $line -notmatch '^\s*([-*]|\d+[.)]|#|\|)' -and $lines[-1] -notmatch '^\s*(#|\|)'
        if ($continues) { $lines[-1] = "$($lines[-1]) $($line.Trim())" } else { $lines.Add($line) }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $header = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*\|') {
            $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
            if ($cells[0] -match '^:?-+:?$') { continue }
            if (-not $header) { $header = $cells; continue }
            $rest = for ($i = 1; $i -lt $cells.Count; $i++) { if ($cells[$i] -and $cells[$i] -ne '-') { "$($header[$i]): $($cells[$i])" } }
            $out.Add("- *$($cells[0])* -- $($rest -join '; ')")
            continue
        }
        $header = $null
        $out.Add($line)
    }
    $text = $out -join "`n"
    $text = $text -replace '\[([^\]]+)\]\((https?://[^)\s]+)\)', '<$2|$1>'
    $text = $text -replace '\*\*([^*]+)\*\*', '*$1*'
    $text = $text -replace '(?m)^#{1,6}\s+(.+)$', '*$1*'
    return ($text -replace "(`n){3,}", "`n`n").Trim()
}

# Groups the Compare table's rows under one heading per verdict, most actionable first, so the
# thread reads as "what the plan missed" rather than a row-by-row diff.
function Format-Compare([string]$body) {
    $rows = @(); $intro = @()
    foreach ($line in ($body -split "`r?`n")) {
        if ($line -notmatch '^\s*\|') { if ($line.Trim()) { $intro += $line.Trim() }; continue }
        $c = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
        if ($c.Count -lt 4 -or $c[0] -in 'task', '' -or $c[0] -match '^:?-+:?$') { continue }
        $rows += [pscustomobject]@{ task = $c[0]; actual = $c[2]; verdict = ($c[3] -replace '[^a-z-]', ''); note = $(if ($c.Count -ge 5) { $c[4] } else { '' }) }
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('### Compare')
    if ($intro) { [void]$sb.AppendLine(($intro -join ' ')) }
    foreach ($v in 'missed', 'extra', 'deferred', 'matched', 'not-shadow-safe') {
        $group = @($rows | Where-Object verdict -eq $v)
        if (-not $group) { continue }
        [void]$sb.AppendLine(); [void]$sb.AppendLine("*$v ($($group.Count))*")
        foreach ($r in $group) {
            $detail = @($r.actual, $r.note) | Where-Object { $_ -and $_ -ne '-' }
            [void]$sb.AppendLine("- *$($r.task)* -- $($detail -join '. ')")
        }
    }
    return (ConvertTo-Mrkdwn $sb.ToString())
}

# Slack cuts a message near 4000 characters; split at line boundaries well short of that.
function Split-Message([string]$text, [int]$max = 3500) {
    $parts = @(); $current = ''
    foreach ($line in ($text -split "`n")) {
        if ($current -and ($current.Length + $line.Length + 1) -gt $max) { $parts += $current.TrimEnd(); $current = '' }
        $current += "$line`n"
    }
    if ($current.Trim()) { $parts += $current.TrimEnd() }
    return $parts
}

$text = Get-Content -Path $Path -Raw
$title = [regex]::Match($text, '(?m)^# (.+)$').Groups[1].Value
$sections = [ordered]@{}
foreach ($m in [regex]::Matches($text, '(?ms)^## ([^\r\n]+)\r?\n(.*?)(?=^## |\z)')) { $sections[$m.Groups[1].Value.Trim()] = $m.Groups[2].Value.Trim() }

$headlineKey = @($sections.Keys | Where-Object { $_ -match 'headline$' })[0]
$questions = @()
if ($sections.Contains('Questions for Gerhard')) {
    $questions = @([regex]::Matches($sections['Questions for Gerhard'], '(?m)^\s*\d+[.)]\s+(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
}

$top = if ($title) { "*$title*`n" } else { '' }
$top += if ($headlineKey) { ConvertTo-Mrkdwn $sections[$headlineKey] -KeepLines } else { '(no headline section; detail in the thread)' }
# Questions show in the top post as well as the thread, so they're seen without opening it; the
# thread copy is the one to react on.
if ($questions) {
    $top += "`n`n:eyes: :question: *$($questions.Count) question(s) for you* -- react on each in the thread: :+1: yes, :-1: no, :point_down: and reply there"
    for ($i = 0; $i -lt $questions.Count; $i++) { $top += "`n*Q$($i + 1).* $(ConvertTo-Mrkdwn $questions[$i])" }
}

$replies = @()
for ($i = 0; $i -lt $questions.Count; $i++) { $replies += ":eyes: :question: *Q$($i + 1).* $(ConvertTo-Mrkdwn $questions[$i])" }
foreach ($key in $sections.Keys) {
    if ($key -eq $headlineKey -or $key -eq 'Questions for Gerhard' -or -not $sections[$key]) { continue }
    $body = if ($key -eq 'Compare') { Format-Compare $sections[$key] } else { ConvertTo-Mrkdwn "### $key`n$($sections[$key])" }
    $replies += Split-Message $body
}

if (-not $PSCmdlet.ShouldProcess($Channel, "post 1 message + $($replies.Count) thread replies")) {
    "----- TOP -----`n$top"
    $n = 0; foreach ($r in $replies) { $n++; "----- REPLY $n ($($r.Length) chars) -----`n$r" }
    return
}

$token = Get-Secret -Name SLACK_DIGEST_BOT_TOKEN -AsPlainText
$headers = @{ Authorization = "Bearer $token" }
function Send-Message([string]$body, [string]$threadTs) {
    $payload = @{ channel = $Channel; text = $body; unfurl_links = $false }
    if ($threadTs) { $payload.thread_ts = $threadTs }
    $r = Invoke-RestMethod -Uri 'https://slack.com/api/chat.postMessage' -Headers $headers -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 3)))
    if (-not $r.ok) { throw "chat.postMessage failed: $($r.error)" }
    $r
}
$first = Send-Message $top $null
foreach ($r in $replies) { [void](Send-Message $r $first.ts) }

# The ledger keeps ts + channel so the next morning run can read the thread for answers.
$ws = (Invoke-RestMethod -Uri 'https://slack.com/api/auth.test' -Headers $headers -Method Post).url.TrimEnd('/')
$permalink = "$ws/archives/$($first.channel)/p$($first.ts -replace '\.', '')"
"[OK] posted 1 message + $($replies.Count) replies to $Channel ts=$($first.ts) channel=$($first.channel) permalink=$permalink"
