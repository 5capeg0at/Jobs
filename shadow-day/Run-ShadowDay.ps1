<#
.SYNOPSIS
Runs one half of a shadow day: the morning plan-and-do, or the evening compare.

.DESCRIPTION
Gathers the day's structured inputs with no model (ADO/git/pipeline record via Enrich-Days.ps1, the
Jobs board snapshot, and for the evening the flattened transcript of the day), fills the prompt
template, runs a headless Sonnet session that may only read external systems, and DMs the result to
Gerhard through the existing Slack bot. Every external write tool is passed to --disallowedTools so
the read-only rule is enforced by the harness, not just the prompt. The morning run never sees the
current day's transcripts, which keeps the evening comparison honest.

.EXAMPLE
Run-ShadowDay.ps1 -Mode morning
Run-ShadowDay.ps1 -Mode evening -Date 2026-09-21 -NoSlack
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('morning', 'evening', 'compare-yesterday')][string]$Mode,
    [datetime]$Date = (Get-Date).Date,
    [string]$Model = 'sonnet',
    [switch]$NoSlack,
    [switch]$Force,
    [switch]$PromptOnly
)
$ErrorActionPreference = 'Stop'
$here = Split-Path $PSCommandPath
$dir = 'C:\Repos\Personal\jobs\docs\183-shadow-day'
$shadow = Join-Path $dir 'shadow'; New-Item -ItemType Directory -Force $shadow | Out-Null
$Date = [datetime]::SpecifyKind($Date.Date, 'Unspecified')

$leaveRanges = @()
foreach ($line in Get-Content (Join-Path $dir 'leave.md')) {
    if ($line -match '^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(\d{4}-\d{2}-\d{2})\s*\|') { $leaveRanges += , @([datetime]$Matches[1], [datetime]$Matches[2]) }
}
function IsOff([datetime]$x) { ($x.DayOfWeek -in 'Saturday', 'Sunday') -or [bool]($leaveRanges | Where-Object { $x -ge $_[0] -and $x -le $_[1] }) }

# The compare runs the next morning so overnight ticket moves credit the right day and the laptop
# can be shut at 18:30. It targets the previous WORKING day; the morning plan still targets today.
if ($Mode -eq 'compare-yesterday') {
    $Mode = 'evening'
    do { $Date = $Date.AddDays(-1) } while (IsOff $Date)
}
$d = $Date.ToString('yyyy-MM-dd')
$out = Join-Path $shadow "$d.md"
$inputs = Join-Path $shadow "$d-inputs-$Mode.md"
$board = Join-Path $shadow "$d-board.json"
$log = Join-Path $shadow "$d-$Mode.log"
function Log($m) { $line = "[$(Get-Date -Format 'HH:mm:ss')] $m"; Add-Content $log $line; Write-Host $line }

# Leave and weekends: nothing to shadow, and no baseline to compare against.
if ((IsOff $Date) -and -not $Force) {
    Log "$d is a weekend or leave day; nothing to shadow (use -Force to run anyway)"
    if ($Mode -eq 'morning') { "# Shadow day $d`n`nWeekend or leave day; no plan." | Set-Content $out -Encoding utf8 }
    return
}
if ($Mode -eq 'evening' -and (Test-Path $out) -and (Get-Content $out -Raw) -match '(?m)^## Compare') {
    Log "$d already has a Compare section; not appending a second one"
    return
}
if ($Mode -eq 'evening' -and -not (Test-Path $out)) {
    "# Shadow day $d`n`n(no morning plan was produced for this day)`n" | Set-Content $out -Encoding utf8
}

# The previous working day's shadow file carries the questions the compare asked Gerhard.
$prev = $Date; do { $prev = $prev.AddDays(-1) } while (IsOff $prev)
$prevFile = Join-Path $shadow "$($prev.ToString('yyyy-MM-dd')).md"
if (-not (Test-Path $prevFile)) { $prevFile = '(none)' }

# Morning looks back to the previous working day's close of business; evening looks at today only.
$since = $Date; do { $since = $since.AddDays(-1) } while (IsOff $since)
$since = $since.AddHours(17)
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('New Zealand Standard Time')
$sinceUtc = [System.TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($since, 'Unspecified'), $tz)
$sinceTs = [int][double]::Parse(([DateTimeOffset]$sinceUtc).ToUnixTimeSeconds())

Log "gathering inputs ($Mode) for $d"
$tmp = Join-Path $env:TEMP "shadow-enrich-$d-$Mode"
# A morning run may only see the record up to 08:00 on the shadow date, so a dry run against a past
# day cannot peek at that day's afternoon; the evening run legitimately sees the whole day.
$from = if ($Mode -eq 'morning') { $since.Date } else { $Date }
$to = if ($Mode -eq 'morning') { $Date.AddHours(8) } else { $Date.AddDays(1) }
& (Join-Path $here 'Enrich-Days.ps1') -From $from -To $to -OutDir $tmp -SkipPrVotes *>> $log
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# System record $($from.ToString('yyyy-MM-dd')) .. $d (gathered $(Get-Date -Format 'HH:mm'))")
foreach ($f in Get-ChildItem $tmp -Filter '*.md' | Sort-Object Name) { [void]$sb.AppendLine((Get-Content $f.FullName -Raw)) }
$sb.ToString() | Set-Content $inputs -Encoding utf8

try {
    $jobs = (Invoke-RestMethod http://localhost:7799/jobs).jobs | Where-Object { $_.status -notin 'Done', 'Removed' } |
        Select-Object num, label, status, repo, branch, next, blockedBy, updatedAt, @{n = 'note'; e = { "$($_.note)".Substring(0, [Math]::Min(300, "$($_.note)".Length)) } }
    $jobs | ConvertTo-Json -Depth 4 | Set-Content $board -Encoding utf8
} catch { Log "board snapshot failed: $($_.Exception.Message)"; '[]' | Set-Content $board }

$dayfile = Join-Path $dir "days\$d.md"
if ($Mode -eq 'evening') {
    & (Join-Path $here 'Flatten-Transcripts.ps1') -Since $Date -OutDir (Join-Path $env:TEMP "shadow-days-$d") *>> $log
    $candidate = Join-Path $env:TEMP "shadow-days-$d\$d.md"
    if (Test-Path $candidate) { Copy-Item $candidate $dayfile -Force } else { Log 'no transcript day-file for today' }
}

$template = Get-Content (Join-Path $here "prompts\$Mode.md") -Raw
$prompt = $template.
    Replace('{{DATE}}', $d).Replace('{{WEEKDAY}}', $Date.DayOfWeek.ToString()).
    Replace('{{OUT}}', $out).Replace('{{CATALOGUE}}', (Join-Path $dir 'catalogue.md')).
    Replace('{{LEAVE}}', (Join-Path $dir 'leave.md')).Replace('{{INPUTS}}', $inputs).
    Replace('{{BOARD}}', $board).Replace('{{DAYFILE}}', $dayfile).Replace('{{PREV}}', $prevFile).
    Replace('{{SINCE}}', $since.ToString('yyyy-MM-dd HH:mm')).Replace('{{SINCE_DATE}}', $since.ToString('yyyy-MM-dd')).
    Replace('{{SINCE_ISO}}', $since.ToString('yyyy-MM-ddTHH:mm:ss')).Replace('{{SINCE_TS}}', "$sinceTs")
$promptFile = Join-Path $shadow "$d-$Mode-prompt.md"
$prompt | Set-Content $promptFile -Encoding utf8
if ($PromptOnly) { Log "prompt rendered to $promptFile (PromptOnly)"; return }

$allowed = @('Read', 'Write', 'Glob', 'Grep', 'ToolSearch', 'Bash(git log*)', 'Bash(git show*)',
    'mcp__claude_ai_Slack__slack_search_public_and_private', 'mcp__claude_ai_Slack__slack_read_channel', 'mcp__claude_ai_Slack__slack_read_thread',
    'mcp__claude_ai_Slack__slack_search_channels', 'mcp__claude_ai_Slack__slack_read_user_profile', 'mcp__claude_ai_Slack__slack_search_users',
    'mcp__claude_ai_Microsoft_365__outlook_calendar_search', 'mcp__claude_ai_Microsoft_365__outlook_email_search', 'mcp__claude_ai_Microsoft_365__get_me',
    'mcp__claude_ai_Microsoft_365__chat_message_search', 'mcp__claude_ai_Microsoft_365__search_people') -join ','
$disallowed = @('SendMessage', 'Edit', 'NotebookEdit', 'Agent', 'Artifact', 'PowerShell',
    'mcp__claude_ai_Slack__slack_send_message', 'mcp__claude_ai_Slack__slack_send_message_draft', 'mcp__claude_ai_Slack__slack_schedule_message',
    'mcp__claude_ai_Slack__slack_create_canvas', 'mcp__claude_ai_Slack__slack_update_canvas',
    'mcp__claude_ai_Microsoft_365__outlook_send_mail', 'mcp__claude_ai_Microsoft_365__outlook_create_draft', 'mcp__claude_ai_Microsoft_365__outlook_update_draft',
    'mcp__claude_ai_Microsoft_365__outlook_send_draft', 'mcp__claude_ai_Microsoft_365__outlook_delete_draft', 'mcp__claude_ai_Microsoft_365__outlook_forward_mail',
    'mcp__claude_ai_Microsoft_365__outlook_create_reply_draft', 'mcp__claude_ai_Microsoft_365__outlook_create_reply_all_draft',
    'mcp__claude_ai_Microsoft_365__outlook_create_event', 'mcp__claude_ai_Microsoft_365__outlook_update_event', 'mcp__claude_ai_Microsoft_365__outlook_delete_event',
    'mcp__claude_ai_Microsoft_365__outlook_respond_to_event', 'mcp__claude_ai_Microsoft_365__outlook_modify_labels', 'mcp__claude_ai_Microsoft_365__outlook_modify_thread_labels',
    'mcp__claude_ai_Microsoft_365__outlook_batch_modify_labels', 'mcp__claude_ai_Microsoft_365__outlook_batch_delete_messages', 'mcp__claude_ai_Microsoft_365__outlook_trash_thread',
    'mcp__claude_ai_Microsoft_365__outlook_untrash_thread', 'mcp__claude_ai_Microsoft_365__outlook_create_filter', 'mcp__claude_ai_Microsoft_365__outlook_delete_filter',
    'mcp__claude_ai_Microsoft_365__outlook_create_label', 'mcp__claude_ai_Microsoft_365__outlook_update_label', 'mcp__claude_ai_Microsoft_365__outlook_delete_label',
    'mcp__claude_ai_Microsoft_365__outlook_set_vacation', 'mcp__claude_ai_Microsoft_365__teams_send_channel_message', 'mcp__claude_ai_Microsoft_365__teams_send_chat_message',
    'mcp__claude_ai_Microsoft_365__teams_reply_channel_message', 'mcp__claude_ai_Microsoft_365__teams_create_chat',
    'mcp__claude_ai_Microsoft_365__sharepoint_upload_file', 'mcp__claude_ai_Microsoft_365__sharepoint_update_file', 'mcp__claude_ai_Microsoft_365__sharepoint_delete_item',
    'mcp__claude_ai_Microsoft_365__sharepoint_move_item', 'mcp__claude_ai_Microsoft_365__sharepoint_copy_item', 'mcp__claude_ai_Microsoft_365__sharepoint_rename_item',
    'mcp__claude_ai_Microsoft_365__sharepoint_create_folder') -join ','

$before = if (Test-Path $out) { (Get-Content $out -Raw).Length } else { 0 }
Log "running claude ($Model, $Mode)"
$env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '0'
Push-Location $dir
try {
    Get-Content $promptFile -Raw | claude --model $Model -p --output-format text --allowedTools $allowed --disallowedTools $disallowed 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
} finally { Pop-Location }

if (-not (Test-Path $out)) { Log "[FAIL] no output written to $out"; exit 1 }
$text = Get-Content $out -Raw
if ($Mode -eq 'evening' -and $text.Length -le $before) { Log '[FAIL] evening run appended nothing'; exit 1 }
Log "[OK] $out ($($text.Length) chars)"

if (-not $NoSlack) {
    $dm = if ($Mode -eq 'evening') { $t = Join-Path $env:TEMP "shadow-dm-$d.md"; $text.Substring($before) | Set-Content $t -Encoding utf8; $t } else { $out }
    & "$HOME\.claude\scripts\send-slack-digest.ps1" -Path $dm *>> $log
    Log 'DM sent'
}
