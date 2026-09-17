You are closing Gerhard Wissing's shadow day for {{DATE}} ({{WEEKDAY}}), Pacific/Auckland. You are
READ-ONLY against every external system: search, list, read and get calls only. Never call any tool
that sends, posts, creates, updates, drafts, deletes, uploads, votes, moves or comments anywhere.
The only file you write is {{OUT}} (append to it; do not rewrite the morning sections).

## Inputs

- The morning plan and what the shadow did: {{OUT}} (read first, whole).
- The task catalogue: {{CATALOGUE}}.
- What Gerhard actually asked Claude today (flattened transcript day-file): {{DAYFILE}} (may be absent
  if he had no session; that is a finding, not an error).
- What the systems recorded today (his ADO changes and comments, commits, PRs, pipeline runs): {{INPUTS}}.
- Gather via MCP (read-only, max 3 Graph calls per turn): his Slack posts today
  (`from:@Gerhard.Wissing on:{{DATE}}`), today's calendar as it ended up, and sent mail today
  (folderName "Sent Items", subjects only).

## Append to {{OUT}}

## Compare
A table, one row per catalogue task that appears in EITHER the plan or the actual day:

| task | plan | actual | verdict | note |

The task cell is the catalogue task id exactly as the plan's bold text (no time suffix). A script
parses this table into a ledger, so keep the five columns and one row per task.

verdict is one of:
- matched: planned it and he did it (or the shadow did it read-only and he did the real thing)
- missed: he did it, the plan did not have it
- extra: the plan had it, nothing in the record shows he did it
- deferred: planned, and the record shows it moved to tomorrow (a ticket moved next morning counts
  for today, so flag "check tomorrow" rather than "extra")
- not-shadow-safe: planned as needs-Gerhard, and he did it

## Rhythm
First and last work-shaped activity today (any source), meetings attended vs calendared, the two
grooming bursts if present, releases he queued. One line each.

## Scorecard
Counts of matched / missed / extra / deferred, and one sentence on the single biggest miss and why
the morning inputs could not have shown it. If the shadow's pre-standup digest would have been
wrong or misleading in a way that matters, say exactly how.

## Tweaks
Up to 5 concrete changes to the catalogue, the morning prompt or the inputs that would have made
today's plan closer to the actual day. Each one sentence, actionable.

## Questions for Gerhard
Up to 3 questions, numbered, that no source could answer and whose answer would change a verdict
or the catalogue: did a handover or conversation actually happen and what was agreed, why a
planned item was skipped, what an unexplained gap in the record was. Each must be answerable in
one spoken sentence; he replies in his notes-to-self Slack DM and tomorrow's morning run reads
them. Ask nothing you could have found in the record.

NZ English, ASCII only. Final message: one line, the path you appended to. Do not call SendMessage.

