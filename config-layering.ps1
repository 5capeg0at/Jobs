# Config loading for the jobs sidecar: a committed base (jobs.config.json) with an
# optional per-machine override (jobs.config.local.json) merged on top. Dot-sourced
# by jobs-sidecar.ps1; also dot-sourced directly by the tests. Reads the script-scope
# $ConfigPath / $LocalConfigPath set by whoever sources it.

function Merge-Config {
    # Deep-merge $Override onto $Base (both ConvertFrom-Json output). JSON objects
    # merge recursively key-by-key; scalars and arrays are replaced by $Override
    # wholesale. Override wins. Returns a new object; inputs are not mutated.
    param($Base, $Override)

    # Leading comma on the returns below: PowerShell unrolls a returned collection
    # into the pipeline, which would collapse a single-element array override (e.g.
    # ["api"]) into a bare scalar. `,$x` wraps it so the caller gets $x back intact.
    if ($null -eq $Override) { return ,$Base }

    # Recurse only when BOTH sides are JSON objects. Arrays and scalars (and any
    # type mismatch) mean $Override replaces $Base outright.
    if ($Base -isnot [System.Management.Automation.PSCustomObject] -or
        $Override -isnot [System.Management.Automation.PSCustomObject]) {
        return ,$Override
    }

    $merged = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties)     { $merged[$p.Name] = $p.Value }
    foreach ($p in $Override.PSObject.Properties) {
        if ($merged.Contains($p.Name)) {
            $merged[$p.Name] = Merge-Config $merged[$p.Name] $p.Value
        } else {
            $merged[$p.Name] = $p.Value
        }
    }
    [pscustomobject]$merged
}

function Merge-RepoUpsert {
    # Pure: returns the local-config object to persist after registering one repo under
    # repos.<Key>. $LocalConfig is the parsed jobs.config.local.json, or $null when the
    # file doesn't exist yet (a fresh clone) — in which case we seed the same shell the
    # example file documents, so a hand-editor opening it later finds what they expect.
    # Every other key is carried through untouched: this file is hand-edited too, and the
    # UI writing one repo must not drop somebody's ado block.
    param($LocalConfig, [string]$Key, [string]$Path, [string]$Trunk)

    $seedComment = 'Personal, per-machine config. Gitignored. Deep-merges over jobs.config.json (objects merge key-by-key, your values win).'
    if ($null -eq $LocalConfig) {
        $LocalConfig = [pscustomobject][ordered]@{ _comment = $seedComment }
    }

    $out = [ordered]@{}
    foreach ($p in $LocalConfig.PSObject.Properties) { $out[$p.Name] = $p.Value }

    $repos = [ordered]@{}
    $existing = $LocalConfig.PSObject.Properties['repos']
    if ($existing -and $existing.Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $existing.Value.PSObject.Properties) { $repos[$p.Name] = $p.Value }
    }
    $repos[$Key] = [pscustomobject][ordered]@{ path = $Path; trunk = $Trunk }

    $out['repos'] = [pscustomobject]$repos
    [pscustomobject]$out
}

function Get-JobsConfig {
    # Base is required; a parse failure here stays fatal, as it was before layering.
    $base = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (Test-Path $LocalConfigPath) {
        try {
            $local = Get-Content $LocalConfigPath -Raw | ConvertFrom-Json
            $base  = Merge-Config $base $local
        } catch {
            Write-Host "[WARN] jobs.config.local.json failed to parse - using base config only. $($_.Exception.Message)"
        }
    }
    $base
}
