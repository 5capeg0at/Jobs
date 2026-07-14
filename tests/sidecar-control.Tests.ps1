# Pester 3.4 (the Windows built-in). Legacy `Should Be` syntax, not `Should -Be`.
# Status probe against a definitely-free port -> deterministic "not running". Process
# launch/kill is integration, proven by manual smoke, not here.

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'sidecar-control.ps1')   # dot-source: exposes helpers, controls nothing

Describe 'Get-SidecarStatus' {
    $cfg = @{ Name = 'Test'; Port = 59998; HealthPath = '/'; MatchPattern = 'no-such-sidecar-xyz.ps1' }

    It 'reports not running when nothing listens on the port' {
        (Get-SidecarStatus -Config $cfg).running | Should Be $false
    }
    It 'echoes name and port from the config' {
        $st = Get-SidecarStatus -Config $cfg
        $st.name | Should Be 'Test'
        $st.port | Should Be 59998
    }
}
