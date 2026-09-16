# Task observation schema

Every classifier writes two files for its period into `C:\Repos\Personal\jobs\docs\183-shadow-day\tasks\`:

- `<period>.json` - machine-mergeable observations (schema below)
- `<period>.md` - short human notes: surprises, ambiguities, anything the schema could not hold

## `<period>.json`

```jsonc
{
  "period": "2026-07a",            // file stem
  "days": [
    {
      "date": "2026-07-14",
      "weekday": "Tuesday",
      "first_prompt": "07:52",       // local time of first human prompt
      "last_prompt": "17:40",
      "sessions": 5,
      "prompts": 41,
      "shape": "Standup prep from board, then 26974 permissioning dev all morning, PR + refinement brief after lunch, env repair at 16:00.",
      "meetings_evident": ["standup ~09:15", "refinement ~14:00"],   // only what the prompts themselves reveal
      "tasks": ["standup-prep", "dev-story", "raise-pr", "refinement-brief", "repair-local-env"]  // task ids seen this day
    }
  ],
  "tasks": [
    {
      "id": "standup-prep",          // kebab-case, stable across days; reuse an id when it is the same task again
      "name": "Prepare standup notes from board and yesterday's pipelines",
      "category": "planning",        // dev | review | refinement | ops-env | comms | planning | harness | research | admin
      "trigger": "daily-morning",    // daily-morning | daily-evening | weekly | sprint | event:<what> | adhoc
      "inputs": ["jobs-board", "ado-pipelines", "git-log"],   // jobs-board | ado-workitems | ado-pipelines | ado-prs | git-log | slack | email | calendar | teams | confluence | local-env | transcripts | web
      "connectors": ["mcp slack", "az devops"],               // tools/MCP actually seen in the session tool tally
      "output": "spoken notes / a message to Gerhard",        // what it produced
      "writes": "none",              // none | local-file | jobs-board | ado | slack | email | repo-commit | deploy
      "judgement": "low",            // low = mechanical, a model can do it read-only; medium = needs context Gerhard holds; high = decision or people call
      "dates": ["2026-07-14", "2026-07-15"],
      "sessions": ["d5faaf8f"],
      "example": "\"what's on the board for today, and did the yellow deploy go through overnight?\"",   // one short quoted prompt
      "automation_hint": "morning scheduled run: read board + last 24h pipeline runs, post to Slack DM"
    }
  ]
}
```

## Rules

- A **task** is a recurring shape of work, not a story. "Implement PBI 26974" and "Implement PBI 27380" are the same task `dev-story`; the PBI numbers go in the day `shape`, not the task id.
- Prefer fewer, well-named tasks. Split only when trigger, inputs or judgement differ materially.
- `dates` and `sessions` must come from the day-files, never guessed. If a task is inferred from one weak hint, say so in the `.md` notes and still record it.
- `meetings_evident` is only what the prompts reveal ("after standup", "refinement at 2"). Calendar enrichment comes later from another source; do not invent it.
- `writes` records the strongest side effect seen. This is what decides whether the shadow day can run the task read-only.
- Skill invocations (`[skill] yeet`, `[skill] jobs`, `/clear`) and agent dispatches are evidence of task boundaries and of Gerhard's harness habits; count them.
- Personal or non-work prompts that slipped in are recorded once as task `personal-noise` and otherwise ignored.
- ASCII only in output ([OK]/[FAIL]/->). NZ English.
