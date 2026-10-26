#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory,[string[]]$LinkerLibraryDirectories=@(),[switch]$UseRustLld,[switch]$Test)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Build-NativeBackend.ps1') @PSBoundParameters -Project RustUI
