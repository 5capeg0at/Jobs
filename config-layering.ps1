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
