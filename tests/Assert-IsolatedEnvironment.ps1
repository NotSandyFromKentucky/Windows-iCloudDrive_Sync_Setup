# This guard is for accidental execution, not a security boundary against forged environment variables.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and $env:RUNNER_OS -eq 'Windows' -and $env:RUNNER_TEMP -and $env:GITHUB_WORKSPACE -and (Test-Path -LiteralPath $env:GITHUB_WORKSPACE -PathType Container)) {
    return 'GitHubHosted'
}
if ($env:USERNAME -eq 'WDAGUtilityAccount' -and (Test-Path -LiteralPath 'C:\TestInput\sandbox-marker.json')) {
    $marker = Get-Content -LiteralPath 'C:\TestInput\sandbox-marker.json' -Raw | ConvertFrom-Json
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $marker.HostSid -and $env:COMPUTERNAME -ne $marker.HostComputer) { return 'WindowsSandbox' }
}
throw 'Integration tests require a disposable Windows Sandbox or GitHub-hosted Windows runner. Self-hosted runners and developer accounts are refused.'
