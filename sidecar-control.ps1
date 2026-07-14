#Requires -Version 7
<#
  Jobs sidecar control — status/start/stop/restart for THIS repo's sidecar only.
  Self-contained: knows nothing about any other repo. Used by hand, by agents, and
  by the personal dev-tray. Dot-source it (InvocationName '.') to get the functions
  without performing an action.

  Robust process tracking: launches via $PSHOME\pwsh.exe (the real exe, never the
  Store-alias pwsh whose command line WMI can't read) and records the launched PID in
  a pidfile. `stop` kills the pidfile's PID plus any command-line match, so it works
  regardless of how the sidecar was started.
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'start', 'stop', 'restart')]
    [string]$Action = 'status'
)

$Sidecar = @{
    Name         = 'Jobs'
    Port         = 7799
    ScriptPath   = Join-Path $PSScriptRoot 'jobs-sidecar.ps1'
    HealthPath   = '/'
    MatchPattern = 'jobs-sidecar.ps1'                   # find the owning pwsh by command line
    LogPath      = Join-Path $env:TEMP 'jobs-sidecar.log'
    PidPath      = Join-Path $env:TEMP 'jobs-sidecar.pid'
}

function Get-SidecarProcess {
    param([string]$Match)
    # Match only genuine `-File <path>\<script>` launches — never a pwsh that merely
    # mentions the script name in a -Command (an agent/tool diagnostic), and never this
    # process itself. Plain command-line-substring matching kills both by accident.
    $rx = '-File\s+\S*' + [regex]::Escape($Match)
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $rx }
}

function Get-SidecarPid {
    param([hashtable]$Config)
    # 1) trust the pidfile if it points at a live pwsh
    if ($Config.PidPath -and (Test-Path -LiteralPath $Config.PidPath)) {
        $filePid = (Get-Content -LiteralPath $Config.PidPath -Raw).Trim()
        if ($filePid -match '^\d+$') {
            $proc = Get-Process -Id ([int]$filePid) -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq 'pwsh') { return [int]$filePid }
        }
    }
    # 2) fall back to a command-line match (works for full-path pwsh launches)
    (Get-SidecarProcess -Match $Config.MatchPattern | Select-Object -First 1).ProcessId
}

function Test-SidecarUp {
    param([int]$Port, [string]$HealthPath)
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:$Port$HealthPath" -TimeoutSec 2 -UseBasicParsing
        return $true
    } catch {
        # An HTTP error response (4xx/5xx) still proves something is listening.
        return ($null -ne $_.Exception.Response)
    }
}

function Get-SidecarStatus {
    param([hashtable]$Config = $Sidecar)
    [pscustomobject]@{
        name    = $Config.Name
        port    = $Config.Port
        running = [bool](Test-SidecarUp -Port $Config.Port -HealthPath $Config.HealthPath)
        pid     = Get-SidecarPid -Config $Config
    }
}

function Start-Sidecar {
    param([hashtable]$Config = $Sidecar)
    if ((Get-SidecarStatus -Config $Config).running) { return "$($Config.Name): already running" }
    $exe = Join-Path $PSHOME 'pwsh.exe'   # the real exe, not the Store alias -> readable command line
    $proc = Start-Process $exe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $Config.LogPath -RedirectStandardError "$($Config.LogPath).err" `
        -ArgumentList '-NoProfile', '-File', $Config.ScriptPath, '-Port', $Config.Port
    if ($Config.PidPath) { Set-Content -LiteralPath $Config.PidPath -Value $proc.Id -Encoding ascii }
    for ($i = 0; $i -lt 20 -and -not (Test-SidecarUp -Port $Config.Port -HealthPath $Config.HealthPath); $i++) {
        Start-Sleep -Milliseconds 250
    }
    "$($Config.Name): started"
}

function Stop-Sidecar {
    param([hashtable]$Config = $Sidecar)
    $ids = @()
    $tracked = Get-SidecarPid -Config $Config
    if ($tracked) { $ids += $tracked }
    $ids += (Get-SidecarProcess -Match $Config.MatchPattern).ProcessId
    $ids | Where-Object { $_ } | Select-Object -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    if ($Config.PidPath -and (Test-Path -LiteralPath $Config.PidPath)) {
        Remove-Item -LiteralPath $Config.PidPath -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 20 -and (Test-SidecarUp -Port $Config.Port -HealthPath $Config.HealthPath); $i++) {
        Start-Sleep -Milliseconds 250
    }
    "$($Config.Name): stopped"
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Action) {
        'status'  { Get-SidecarStatus | ConvertTo-Json -Compress }
        'start'   { Start-Sidecar }
        'stop'    { Stop-Sidecar }
        'restart' { Stop-Sidecar; Start-Sidecar }
    }
}
