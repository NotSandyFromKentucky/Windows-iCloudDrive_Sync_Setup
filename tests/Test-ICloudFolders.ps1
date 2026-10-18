#requires -Version 5.1
# Dependency-free regression tests: fake registry, real isolated filesystem.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $repo ('.test-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$module = Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
$script:passed = 0
function Assert($Condition, $Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like "*$Pattern*") "Expected failure containing '$Pattern'; got '$caught'"
}
function Pass($Name) { $script:passed++; Write-Host "PASS: $Name" }
try {
    # Replace only the private registry/recovery boundary. No HKCU writes.
    & $module {
        param($Workspace)
        $script:TestWorkspace = $Workspace
        $script:Fake = @{}
        $script:WriteCount = 0
        $script:FailAt = 0
        function script:Get-RecoveryRoot { Join-Path $script:TestWorkspace 'recovery' }
        $script:RegisteredRoots = @()
        function script:Get-RegisteredICloudRoots { $script:RegisteredRoots }
        function script:Out-Host { param([Parameter(ValueFromPipeline)]$InputObject) process { } }
        function script:Write-Host { param([Parameter(ValueFromRemainingArguments)]$Objects) }
        function script:Read-FolderValue {
            param([string]$Name)
            if ($script:Fake.ContainsKey($Name)) { return $script:Fake[$Name] }
            [pscustomobject]@{ Name=$Name; Exists=$false; Kind=$null; Data=$null }
        }
        function script:Write-FolderValue {
            param($Value)
            $script:WriteCount++
            if ($script:FailAt -eq $script:WriteCount) { throw 'Injected registry failure' }
            if ($Value.Exists) { $script:Fake[$Value.Name] = $Value } else { $script:Fake.Remove($Value.Name) }
        }
    } $testRoot
    $cloud = Join-Path $testRoot 'cloud ! with spaces'
    $null = [IO.Directory]::CreateDirectory($cloud)
    Invoke-ICloudFolders -ICloudRoot $cloud
    Assert (@(Get-ChildItem -LiteralPath $cloud -Force).Count -eq 0) 'Preview created folders'
    Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'recovery'))) 'Preview created recovery data'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Preview wrote registry'
    Pass 'preview is read only'

    Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -WhatIf
    Assert (@(Get-ChildItem -LiteralPath $cloud -Force).Count -eq 0) 'WhatIf created folders'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'WhatIf wrote registry'
    Pass 'WhatIf is read only'

    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply } 'VerifiedSyncRoot'
    Pass 'apply requires sync-root verification'

    & $module { param($Workspace) $script:RegisteredRoots = @(Join-Path $Workspace 'different-cloud') } $testRoot
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot } 'does not match'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Root mismatch changed settings'
    & $module { $script:RegisteredRoots = @() }
    Pass 'registered root mismatch cannot be overridden'

    $probeFunction = & $module { (Get-Item Function:Test-DestinationAccess).ScriptBlock }
    & $module { function script:Test-DestinationAccess { param($Paths) throw 'Injected access denied' } }
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot } 'Injected access denied'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Access failure changed registry'
    & $module { param($Original) Set-Item Function:script:Test-DestinationAccess -Value $Original } $probeFunction
    Pass 'destination write failure stops before registry writes'

    $obstruction = Join-Path $cloud 'Videos'
    [IO.File]::WriteAllText($obstruction, 'occupied')
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot } 'occupied by a file'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Obstruction changed registry'
    Remove-Item -LiteralPath $obstruction
    Pass 'file obstruction stops before registry writes'

    $source = Join-Path $testRoot 'old desktop'
    $null = [IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'keep.txt'), 'keep')
    & $module {
        param($Source)
        $script:Fake['Desktop'] = [pscustomobject]@{ Name='Desktop'; Exists=$true; Kind='String'; Data=$Source }
        $rawSource = $Source.Replace($env:USERPROFILE, '%USERPROFILE%')
        $script:Fake['Personal'] = [pscustomobject]@{ Name='Personal'; Exists=$true; Kind='ExpandString'; Data=$rawSource }
        $script:Fake['Unrelated'] = [pscustomobject]@{ Name='Unrelated'; Exists=$true; Kind='String'; Data='untouched' }
    } $source
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot } 'requires review'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Content preflight changed registry'
    Pass 'existing source content requires explicit opt-in'

    & $module { $script:FailAt = 3 }
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -AllowExistingContent } 'Original settings retained/restored'
    Assert ((& $module { $script:Fake.Count }) -eq 3) 'Rollback retained newly introduced values'
    Assert ((& $module { $script:Fake['Desktop'].Kind }) -eq 'String') 'Rollback lost original type'
    Assert ((& $module { $script:Fake['Desktop'].Data }) -ceq $source) 'Rollback lost original path'
    Assert ((& $module { $script:Fake['Personal'].Data }) -ceq $source.Replace($env:USERPROFILE, '%USERPROFILE%')) 'Rollback expanded original tokens'
    Pass 'partial failure restores exact original values and absence'

    & $module { $script:FailAt = 0 }
    Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -AllowExistingContent
    Assert ((& $module { $script:Fake['My Pictures'].Data -ceq $script:Fake['{0DDD015D-B06C-45D5-8C4C-F59713854639}'].Data })) 'Pictures aliases differ'
    Assert ((& $module { -not $script:Fake.ContainsKey('{339719B5-8C47-4894-94C2-D8F77ADD44A6}') })) 'OneDrive mapping changed'
    Assert ((& $module { -not $script:Fake.ContainsKey('My Music') })) 'Music changed by default'
    Assert ((& $module { $script:Fake['Unrelated'].Data }) -ceq 'untouched') 'Unrelated value changed'
    Assert (Test-Path -LiteralPath (Join-Path $source 'keep.txt')) 'Source file was moved/deleted'
    Pass 'apply verifies canonical aliases, scope, special characters and preserves files'

    $state = & $module { @($script:Fake.Keys | Sort-Object | ForEach-Object { $script:Fake[$_] }) | ConvertTo-Json -Depth 6 -Compress }
    Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot
    Assert ((& $module { @($script:Fake.Keys | Sort-Object | ForEach-Object { $script:Fake[$_] }) | ConvertTo-Json -Depth 6 -Compress }) -ceq $state) 'Second run drifted'
    Pass 'second run preserves configuration'

    $backups = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'recovery') -Recurse -Filter before.json | Sort-Object FullName)
    $original = @($backups | Where-Object {
        $b = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        @($b.Values | Where-Object { $_.Name -eq 'Desktop' -and $_.Data -eq $source }).Count -eq 1
    })[0].FullName
    Invoke-ICloudFolders -RestoreBackup $original -Apply
    Assert ((& $module { $script:Fake.Count }) -eq 3) 'Restore did not remove originally absent values'
    Assert ((& $module { $script:Fake['Desktop'].Data }) -ceq $source) 'Restore lost Desktop'
    Pass 'manual restore uses validated backup and preserves unrelated values'

    $invalid = Get-Content -LiteralPath $original -Raw | ConvertFrom-Json
    $invalid.Values[0].Name = 'AppData'
    $invalidPath = Join-Path $testRoot 'invalid.json'
    $invalid | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $invalidPath -Encoding UTF8
    Expect-Failure { Invoke-ICloudFolders -RestoreBackup $invalidPath -Apply } 'Unexpected or duplicate'
    Pass 'restore rejects out-of-scope registry entries'

    Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -AllowExistingContent -IncludeMusic
    Assert ((& $module { $script:Fake['My Music'].Data -ceq $script:Fake['{A0C69A99-21C8-4671-8703-7934162FCF1D}'].Data })) 'Music aliases differ'
    Pass 'optional Music aliases agree'

    $writesBefore = & $module { $script:WriteCount }
    $invalid.Sid = 'S-1-0-0'
    $invalid | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $invalidPath -Encoding UTF8
    Expect-Failure { Invoke-ICloudFolders -RestoreBackup $invalidPath -Apply } 'SID'
    Assert ((& $module { $script:WriteCount }) -eq $writesBefore) 'Foreign-user backup changed settings'
    Pass 'restore rejects another user backup'

    $unicodeCloud = Join-Path $testRoot ('cloud-' + [char]0x00E9)
    $null = [IO.Directory]::CreateDirectory($unicodeCloud)
    & $module { param($Root) $script:RegisteredRoots = @($Root) } $unicodeCloud
    Invoke-ICloudFolders -ICloudRoot $unicodeCloud -Apply -AllowExistingContent
    Assert ((& $module { $script:Fake['Desktop'].Data }) -ceq (Join-Path $unicodeCloud 'Desktop')) 'Unicode root changed'
    Pass 'registered root applies without fallback flag and preserves Unicode'

    & $module { $script:WriteCount = 0; $script:FailAt = @(3,4) }
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -AllowExistingContent } 'does not match'
    & $module { $script:RegisteredRoots = @() }
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -AllowExistingContent } 'ROLLBACK INCOMPLETE'
    Pass 'rollback failure is reported with recovery information'
    Write-Host "$script:passed tests passed. No user-shell registry values were written."
} finally {
    Remove-Module $module -Force
    # Only this test's unique directory beneath the verified repository is removed.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\') + '\.test-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
