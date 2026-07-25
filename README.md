# Jobs

A single-user kanban board for tracking dev work, run entirely locally. A PowerShell 7
sidecar serves a single-file HTML board and a small JSON API; the data lives in one
`jobs.json` file next to the app. No build step, no database, no external service.

It also has an optional **Assigned (ADO)** mode that shapes your current-sprint Azure
DevOps work into a read-only rail, and a background sweep that auto-closes a job when its
linked ADO pull request merges or is abandoned. Both are opt-in — the board works fine
without ever touching Azure DevOps.

## Requirements

- PowerShell 7+ (`pwsh`)
- (Optional) the Azure CLI (`az`), signed in, for ADO Assigned mode and PR auto-close

## Run it

```powershell
pwsh -NoProfile -File .\jobs-sidecar.ps1 [-Port 7799]
# then open http://localhost:7799
```

The board starts empty. Add jobs from the UI; they're written to `jobs.json` (gitignored)
in the app directory. `sidecar-control.ps1` gives you status/start/stop/restart if you'd
rather manage it from a script.

## Configuration

`jobs.config.json` holds the defaults; copy `jobs.config.local.example.json` to
`jobs.config.local.json` (gitignored) and override anything per-machine — it deep-merges
over the base, your values win. The pieces:

- **`port`** — the sidecar's default listen port.
- **`ado`** — your Azure DevOps org/project/team and work-item URL templates. Only needed
  for Assigned mode. Point these at your own org.
- **`prCheck.intervalSec`** — how often the background PR-status sweep runs.
- **`repos`** — the repos a job can be pinned to. A job stores the repo *key*; the sidecar
  resolves its path + trunk here to draw the detail card's commit graph and to run
  `audit-done-jobs.ps1`. Edit these to point at your own repos. `POST /jobs` rejects a key
  that isn't in the map and names the valid ones, so a typo surfaces at write time rather
  than as an "unknown repo" graph later; `GET /config` returns the merged map if you'd
  rather look first.

## Files

- `jobs-sidecar.ps1` — the server: an `HttpListener` that serves `jobs.html` and the API
  (`/jobs` CRUD, `/ado/assigned`, `/git/branch(es)`/`/git/log` for the commit graph,
  `/config`, `/open`, `/poll/{script}`, `/briefs/{path}`). A background PR-status sweep runs
  off the main request loop on `prCheck.intervalSec`.
- `jobs.html` — the whole UI in one file: a narrow-viewport rail, a wide-viewport kanban
  board, a detail card with a commit graph, search, and the ADO Assigned mode.
- `jobs.config.json` / `jobs.config.local.example.json` — config + the per-machine override
  template.
- `config-layering.ps1` — the deep-merge config loader shared by the sidecar and scripts.
- `check-pr-status.ps1` — the PR sweep: flips a `PR`-status job to Done/Parked when its
  linked ADO pull request merges or is abandoned. Plain string comparison against `az`, no
  LLM in the loop.
- `audit-done-jobs.ps1` — a by-hand check for `Done` jobs whose branch never merged.
- `sidecar-control.ps1` — status/start/stop/restart for the sidecar.
- `tests/` — Pester covering the pure CRUD/ADO/PR-sweep logic (no listener needed). Uses the
  legacy `Should Be` syntax; run with Pester 3.4 explicitly:
  `Import-Module Pester -RequiredVersion 3.4.0` (5.x breaks it).

## Remote access

The sidecar binds `localhost` by default. If you want to reach the board from your phone,
it works cleanly behind [Tailscale](https://tailscale.com)'s `tailscale serve` — bind the
wildcard prefix once (`netsh http add urlacl url=http://+:7799/`, elevated) and point
`tailscale serve` at the port. That's optional; nothing in the app requires it.

## Optional: morning briefs

If a `~/.claude/scheduled-prompts/briefs/` directory exists, the sidecar serves its
`*-morning-brief.html` files (and screenshots) at `/briefs/`, path-traversal guarded. If the
directory isn't there, the route simply does nothing — it's a hook for a separate
brief-generating workflow, not a dependency.
