#requires -Version 5.1
param([Parameter(Mandatory)][string]$WorkerPath,[string]$BackendWorkerPath,[switch]$RunNativeIntegration)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Test-RustUIParity.ps1') -WorkerPath $WorkerPath -BackendWorkerPath $BackendWorkerPath -RunNativeIntegration:$RunNativeIntegration.IsPresent
