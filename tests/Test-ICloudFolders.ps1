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

    # Validation must remain before writes even for damaged/untrusted backups.
    $writeCount = & $module { $script:WriteCount }
    $bad = Get-Content -LiteralPath $original -Raw | ConvertFrom-Json
    $bad.Values = @($bad.Values) + @($bad.Values[0])
    $bad | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $invalidPath -Encoding UTF8
    Expect-Failure { Invoke-ICloudFolders -RestoreBackup $invalidPath -Apply } 'duplicate'
    $bad = Get-Content -LiteralPath $original -Raw | ConvertFrom-Json
    $bad.Values[0].Kind = 'DWord'
    $bad | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $invalidPath -Encoding UTF8
    Expect-Failure { Invoke-ICloudFolders -RestoreBackup $invalidPath -Apply } 'Invalid registry value'
    $bad = Get-Content -LiteralPath $original -Raw | ConvertFrom-Json
    $bad.Values[0].Data = Join-Path $testRoot 'missing-original-path'
    $bad | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $invalidPath -Encoding UTF8
    Expect-Failure { Invoke-ICloudFolders -RestoreBackup $invalidPath -Apply } 'Restore destination is unavailable'
    '{invalid JSON' | Set-Content -LiteralPath $invalidPath
    Expect-Failure { Invoke-ICloudFolders -RestoreBackup $invalidPath -Apply } ''
    Assert ((& $module { $script:WriteCount }) -eq $writeCount) 'Invalid backup changed settings'
    Pass 'duplicate, invalid-type, unavailable-path and malformed backups are rejected before writes'

    $savedRead = & $module { (Get-Item Function:Read-FolderValue).ScriptBlock }
    & $module { function script:Read-FolderValue { param($Name) throw 'Injected registry access denied' } }
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot } 'registry access denied'
    & $module { param($Original) Set-Item Function:script:Read-FolderValue -Value $Original } $savedRead
    Assert ((& $module { $script:WriteCount }) -eq $writeCount) 'Registry read failure changed settings'
    Pass 'registry access failure stops before writes'

    $savedWrite = & $module { (Get-Item Function:Write-FolderValue).ScriptBlock }
    & $module {
        $script:FailAt = 0
        $script:CorruptOnce = $true
        function script:Write-FolderValue {
            param($Value)
            $script:WriteCount++
            if ($Value.Exists) {
                $data = $Value.Data
                if ($script:CorruptOnce) { $script:CorruptOnce = $false; $data += '-corrupted' }
                $script:Fake[$Value.Name] = [pscustomobject]@{ Name=$Value.Name; Exists=$true; Kind=$Value.Kind; Data=$data }
            } else { $script:Fake.Remove($Value.Name) }
        }
    }
    $snapshot = & $module { @($script:Fake.Keys | Sort-Object | ForEach-Object { $script:Fake[$_] }) | ConvertTo-Json -Depth 6 -Compress }
    Expect-Failure { Invoke-ICloudFolders -ICloudRoot $cloud -Apply -VerifiedSyncRoot -AllowExistingContent } 'Read-back mismatch'
    Assert ((& $module { @($script:Fake.Keys | Sort-Object | ForEach-Object { $script:Fake[$_] }) | ConvertTo-Json -Depth 6 -Compress }) -ceq $snapshot) 'Read-back mismatch failed to restore prior snapshot'
    & $module { param($Original) Set-Item Function:script:Write-FolderValue -Value $Original } $savedWrite
    Pass 'read-back corruption is detected and rolled back'
    # Defaults use an isolated profile fixture, never the developer's destinations.
    $profile = Join-Path $testRoot 'local profile'
    $null = [IO.Directory]::CreateDirectory($profile)
    & $module {
        param($Profile, $Source)
        $script:DefaultProfile = $Profile
        $script:DefaultQueryFailure = $false
        function script:Get-WindowsDefaultFolderPath {
            param([guid]$Id)
            if ($script:DefaultQueryFailure) { throw 'Injected Windows default-path query failure' }
            $folders = @{
                'b4bfcc3a-db2c-424c-b029-7fe99a87c641'='Desktop'
                'fdd39ad0-238f-46af-adb4-6c85480369c7'='Documents'
                '33e28130-4e1e-4676-835a-98395c3bc3bb'='Pictures'
                '18989b1d-99b5-455b-841c-ab7c74e4ddfc'='Videos'
                '374de290-123f-4565-9164-39c4925e467b'='Downloads'
                'edc0fe71-98d8-4f4a-b920-c8dc133cb165'='Videos-Captures'
                '4bd8d571-6d19-48d3-be97-422220080e43'='Music'
            }
            if (-not $folders.ContainsKey($Id.ToString())) { throw "Unexpected Windows folder ID: $Id" }
            # Deliberately unlike guessed USERPROFILE paths, and initially absent.
            Join-Path $script:DefaultProfile ('Windows default ' + $folders[$Id.ToString()])
        }
        function script:Get-RegisteredICloudRoots { throw 'Reset must not consult iCloud registration' }
        $script:Fake = @{
            Desktop = [pscustomobject]@{Name='Desktop';Exists=$true;Kind='String';Data=$Source}
            Unrelated = [pscustomobject]@{Name='Unrelated';Exists=$true;Kind='String';Data='untouched'}
        }
        $script:WriteCount = 0
        $script:FailAt = 0
        $script:ResetRecovery = Join-Path $script:TestWorkspace 'reset-recovery'
        function script:Get-RecoveryRoot { $script:ResetRecovery }
    } $profile $source
    Invoke-ICloudFolders -ResetToDefaults
    Invoke-ICloudFolders -ResetToDefaults -Apply -AllowExistingContent -WhatIf
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Reset preview/WhatIf wrote registry'
    Assert (@(Get-ChildItem -LiteralPath $profile -Force).Count -eq 0) 'Reset preview/WhatIf created destinations'
    Assert (-not (Test-Path (Join-Path $testRoot 'reset-recovery'))) 'Reset preview/WhatIf created backup'
    Pass 'reset preview and WhatIf are read only and independent of iCloud'

    & $module { $script:DefaultQueryFailure = $true }
    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -Apply -AllowExistingContent } 'default-path query failure'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Default API failure wrote registry'
    Assert (-not (Test-Path (Join-Path $testRoot 'reset-recovery'))) 'Default API failure created backup'
    & $module { $script:DefaultQueryFailure = $false }
    Pass 'Windows default-path query failure aborts without guessed destinations or writes'

    $corruptBackup = Join-Path $testRoot 'reset-recovery\old-broken\before.json'
    $null = [IO.Directory]::CreateDirectory((Split-Path $corruptBackup))
    [IO.File]::WriteAllText($corruptBackup, 'broken old backup')

    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -Apply } 'requires review'
    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -ICloudRoot $cloud } 'cannot be combined'
    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -RestoreBackup $original } 'cannot be combined'
    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -IncludeMusic } 'cannot be combined'
    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -VerifiedSyncRoot } 'cannot be combined'
    Assert ((& $module { $script:WriteCount }) -eq 0) 'Rejected reset wrote registry'
    Pass 'reset requires source-content review and rejects conflicting modes'

    & $module { $script:FailAt = 4 }
    Expect-Failure { Invoke-ICloudFolders -ResetToDefaults -Apply -AllowExistingContent } 'Original settings retained/restored'
    Assert ((& $module { $script:Fake.Count -eq 2 -and $script:Fake['Desktop'].Kind -ceq 'String' -and -not $script:Fake.ContainsKey('Personal') })) 'Reset rollback lost type or absent aliases'
    Assert ((& $module { $script:Fake['Desktop'].Data }) -ceq $source) 'Reset rollback lost original path'
    Pass 'partial reset rolls back exact values and removes introduced aliases'

    & $module { $script:FailAt = 0 }
    Invoke-ICloudFolders -ResetToDefaults -Apply -AllowExistingContent
    & $module {
        $map = Get-FolderMap -IncludeMusic
        foreach ($name in $map.Keys) {
            $expected = Join-Path $script:DefaultProfile ('Windows default ' + $map[$name].Replace('\','-'))
            if ($script:Fake[$name].Data -cne $expected -or $script:Fake[$name].Kind -cne 'ExpandString') { throw "Incorrect default for $name" }
        }
        if ($script:Fake.Count -ne 14 -or $script:Fake.Unrelated.Data -cne 'untouched') { throw 'Reset scope changed' }
    }
    Assert ([IO.File]::ReadAllText((Join-Path $source 'keep.txt')) -ceq 'keep') 'Reset moved/deleted source content'
    Pass 'reset covers all seven folders and aliases including Music while retaining content and unrelated values'
    Assert ([IO.File]::ReadAllText($corruptBackup) -ceq 'broken old backup') 'Reset read or altered old corrupt backup'
    Pass 'reset succeeds using Windows-supplied defaults despite a corrupt historical backup'

    $resetBackup = @(Get-ChildItem (Join-Path $testRoot 'reset-recovery') -Recurse -Filter before.json | Where-Object {$_.FullName -ne $corruptBackup})[0].FullName
    Invoke-ICloudFolders -RestoreBackup $resetBackup -Apply
    Assert (& $module { $script:Fake.Count -eq 2 -and $script:Fake.Desktop.Kind -ceq 'String' -and $script:Fake.Desktop.Data -ceq $args[0] } $source) 'Reset backup failed to restore exact original state'
    Pass 'reset backup reverses the reset including originally absent Music aliases'
    $definitions=@(Get-ICloudFolderDefinitions)
    Assert ($definitions.Count -eq 7 -and ($definitions|Where-Object Id -eq 'Captures').RelativePath -ceq 'Videos\Captures') 'Folder definitions differ from the central map'
    & $module {
        param($Workspace,$Original)
        $script:RegisteredRoots=@();$script:WriteCount=0;$script:FailAt=0
        function script:Get-RegisteredICloudRoots {$script:RegisteredRoots}
        $script:Fake=@{Desktop=[pscustomobject]@{Name='Desktop';Exists=$true;Kind='String';Data=$Original};Unrelated=[pscustomobject]@{Name='Unrelated';Exists=$true;Kind='String';Data='untouched'}}
        $script:CustomRecovery=Join-Path $Workspace 'custom-recovery'
        function script:Get-RecoveryRoot {$script:CustomRecovery}
    } $testRoot $source
    $customDocuments=Join-Path $cloud ("Personal files ' & "+[char]0x00E9)
    $paths=@{Documents=$customDocuments}
    Invoke-ICloudFolders -ICloudRoot $cloud -FolderPaths $paths
    Invoke-ICloudFolders -ICloudRoot $cloud -FolderPaths $paths -Apply -VerifiedSyncRoot -AllowExistingContent -WhatIf
    Assert ((& $module {$script:WriteCount}) -eq 0 -and -not(Test-Path $customDocuments)) 'Custom preview/WhatIf wrote settings or created paths'
    foreach($invalid in @(@{OneDrive=(Join-Path $cloud 'Other')},@{Documents=$testRoot},@{Documents='relative'},@{Documents=''},@{Documents=(Join-Path $cloud 'Desktop')},@{Desktop=(Join-Path $cloud 'Documents\Nested')},@{Music=(Join-Path $cloud 'Songs')})){
        $rejected=$false;try{Invoke-ICloudFolders -ICloudRoot $cloud -FolderPaths $invalid}catch{$rejected=$true};Assert $rejected 'Invalid custom folder plan was accepted'
    }
    Expect-Failure {Invoke-ICloudFolders -ResetToDefaults -FolderPaths $paths} 'cannot be combined'
    Expect-Failure {Invoke-ICloudFolders -RestoreBackup $resetBackup -FolderPaths $paths} 'cannot be combined'
    Assert ((& $module {$script:WriteCount}) -eq 0) 'Rejected custom paths wrote registry'
    Pass 'central folder definitions, custom preview/WhatIf, scope/overlap validation and reset/restore exclusion'
    & $module {$script:FailAt=3}
    Expect-Failure {Invoke-ICloudFolders -ICloudRoot $cloud -FolderPaths $paths -Apply -VerifiedSyncRoot -AllowExistingContent} 'Original settings retained/restored'
    Assert (& $module {$script:Fake.Count -eq 2 -and $script:Fake.Desktop.Kind -ceq 'String' -and -not $script:Fake.ContainsKey('Personal')}) 'Custom failure lost exact state or introduced absent values'
    & $module {$script:FailAt=0;$script:WriteCount=0}
    Invoke-ICloudFolders -ICloudRoot $cloud -FolderPaths $paths -Apply -VerifiedSyncRoot -AllowExistingContent
    Assert (& $module {param($Expected) $script:Fake.Personal.Data -ceq $Expected -and $script:Fake['{F42EE2D3-909F-4907-8871-4C22FC0BF756}'].Data -ceq $Expected -and $script:Fake.Unrelated.Data -ceq 'untouched'} $customDocuments) 'Custom paths lost aliases or changed unrelated settings'
    $customBackup=@(Get-ChildItem (Join-Path $testRoot 'custom-recovery') -Recurse -Filter before.json)[0].FullName
    Invoke-ICloudFolders -RestoreBackup $customBackup -Apply
    Assert (& $module {$script:Fake.Count -eq 2 -and $script:Fake.Desktop.Kind -ceq 'String' -and -not $script:Fake.ContainsKey('Personal')}) 'Custom backup failed exact restoration'
    Pass 'custom destinations share aliases, retain originals and preserve exact rollback/backup restoration'
    Write-Host "$script:passed tests passed. No user-shell registry values were written."
} finally {
    Remove-Module $module -Force
    # Only this test's unique directory beneath the verified repository is removed.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\') + '\.test-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
