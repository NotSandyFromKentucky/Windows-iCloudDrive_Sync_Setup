#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkerPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$WorkerPath=(Resolve-Path -LiteralPath $WorkerPath).Path
if(-not $env:ICLOUD_TEST_DESKTOP){
    & (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{WorkerPath=$WorkerPath} -TimeoutSeconds 300
    return
}
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
$isolation=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if($isolation -notin @('GitHubHosted','WindowsSandbox')){throw 'Native backend integration tests require a disposable Windows environment.'}
function Assert($Value,[string]$Message){
    if(-not $Value){
        $safeMessage=$Message
        if($safeMessage -like 'Unexpected result:*' -or $safeMessage -match '(?i)(?:[a-z]:\\|\\\\)'){
            $safeMessage='A native backend assertion failed; result or path details were withheld.'
        }
        $safeMessage=$safeMessage -replace '[\r\n]',' ' -replace '%','%25' -replace ':','%3A' -replace ',','%2C'
        Write-Output "::error title=Native backend assertion::$safeMessage"
        if($env:GITHUB_STEP_SUMMARY -and (Test-Path -LiteralPath $env:GITHUB_STEP_SUMMARY)){
            [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,"Native backend assertion: $safeMessage`n")
        }
        if($env:RUNNER_TEMP){
            $assertionPath=Join-Path $env:RUNNER_TEMP 'ICloudNativeBackendAssertion.txt'
            [IO.File]::WriteAllText($assertionPath,$safeMessage,(New-Object Text.UTF8Encoding($false)))
        }
        throw 'Native backend assertion failed.'
    }
}
function Invoke-Worker([string]$Request,[bool]$Success=$true){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$WorkerPath;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $process=[Diagnostics.Process]::Start($info)
    try{
        $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
        $bytes=[Text.Encoding]::UTF8.GetBytes($Request)
        $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.Close()
        if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Worker timeout'}
        $lines=@($out.Result -split '\r?\n' | Where-Object {$_} | ForEach-Object {$_ | ConvertFrom-Json})
        Assert ($lines.Count -gt 0) 'Worker returned no protocol records'
        Assert ($lines[-1].type -eq 'result') 'Missing terminal result'
        Assert ($lines[-1].ok -eq $Success) ('Unexpected result: '+$out.Result)
        Assert (($process.ExitCode -eq 0) -eq $Success) 'Exit code disagrees with result'
        Assert ($err.Result -eq '') 'Unexpected stderr output'
        return $lines
    }finally{if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ICloudNativeFixture-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try{
    $module=Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
    $expected=@(& $module {
        $m=Get-FolderMap -IncludeMusic;$known=Get-WindowsKnownFolderIds
        foreach($name in $m.Keys){$relative=$m[$name];$id=if($relative -eq 'Videos\Captures'){'Captures'}else{$relative};[pscustomobject]@{value_name=$name;relative_path=$relative;known_folder_id=$known[$id]}}
    })
    $actual=(Invoke-Worker '{"version":1,"operation":"metadata"}')[0].mappings
    Assert ($actual.Count -eq $expected.Count) 'Generated metadata count differs from central map'
    for($i=0;$i -lt $expected.Count;$i++){
        Assert ($actual[$i].value_name -ceq $expected[$i].value_name -and $actual[$i].relative_path -ceq $expected[$i].relative_path -and $actual[$i].known_folder_id -ceq $expected[$i].known_folder_id) 'Generated alias or Known Folder metadata drift'
    }
    'PASS: build-time aliases and Known Folder IDs match the central mapping'
    $expectedDefaults=@();$defaultQueryError=$null
    try {
        $expectedDefaults=@(& $module {
            $ids=Get-WindowsKnownFolderIds
            foreach($folder in $ids.Keys){[pscustomobject]@{folder=$folder;path=(Get-NormalPath (Get-WindowsDefaultFolderPath -Id $ids[$folder]))}}
        })
    } catch { $defaultQueryError=$_.Exception.Message }
    if($defaultQueryError){
        $nativeFailure=Invoke-Worker '{"version":1,"operation":"defaults"}' $false
        Assert ($nativeFailure[-1].message -like '*SHGetKnownFolderPath failed*HRESULT*') 'Rust did not refuse unavailable Windows defaults explicitly'
        'PASS: Rust refuses to guess when Windows and the PowerShell reference cannot supply default paths'
    } else {
        $nativeDefaults=(Invoke-Worker '{"version":1,"operation":"defaults"}')[0]
        Assert ($nativeDefaults.type -ceq 'defaults' -and $nativeDefaults.folders.Count -eq $expectedDefaults.Count) 'Rust default-folder lookup returned an incomplete set'
        foreach($expectedFolder in $expectedDefaults){
            $actualFolder=@($nativeDefaults.folders|Where-Object {$_.folder -ceq $expectedFolder.folder})
            Assert ($actualFolder.Count -eq 1 -and [string]::Equals($actualFolder[0].path,$expectedFolder.path,[StringComparison]::OrdinalIgnoreCase)) ('Rust Known Folder API differs for '+$expectedFolder.folder)
        }
        # Preserve the OrderedDictionary as one keyed object. Wrapping this
        # command in @() turns it into an array, whose string-key lookup
        # silently returns $null in Windows PowerShell 5.1.
        $resetMap=& $module { Get-FolderMap -IncludeMusic -SystemDefaults }
        Assert ($resetMap -is [System.Collections.IDictionary]) 'PowerShell reset mapping did not remain keyed'
        foreach($name in $resetMap.Keys){$relative=$expected|Where-Object {$_.value_name -ceq $name}|Select-Object -First 1;$folder=if($relative.relative_path -eq 'Videos\Captures'){'Captures'}else{$relative.relative_path};$default=$expectedDefaults|Where-Object {$_.folder -ceq $folder}|Select-Object -First 1;Assert ([string]::Equals($resetMap[$name],$default.path,[StringComparison]::OrdinalIgnoreCase)) ('Windows reset mapping changed for '+$name)}
        'PASS: Rust resolves Windows default folders through SHGetKnownFolderPath without writes'
    }
    $expectedCurrent=@();$currentPathFailures=@()
    $currentIds=& $module { Get-WindowsKnownFolderIds }
    foreach($folder in $currentIds.Keys){
        try{$expectedCurrent+=,[pscustomobject]@{folder=$folder;path=(Get-WindowsCurrentFolderPath -Id $currentIds[$folder])}}
        catch{$currentPathFailures+=,[pscustomobject]@{folder=$folder;message=$_.Exception.Message}}
    }
    if($currentPathFailures.Count){
        $nativeCurrentFailure=Invoke-Worker '{"version":1,"operation":"resolve"}' $false
        $nativeMessage=[string]$nativeCurrentFailure[-1].message
        $matchingFailure=$false
        $comparisonDetails=New-Object 'System.Collections.Generic.List[string]'
        foreach($failure in $currentPathFailures){
            $hresultMatch=[regex]::Match($failure.message,'HRESULT\s+(0x[0-9A-Fa-f]{8}|-?\d+)')
            if(-not $hresultMatch.Success){$comparisonDetails.Add("$($failure.folder)=unparsed PowerShell HRESULT");continue}
            $hresultText=$hresultMatch.Groups[1].Value
            if($hresultText.StartsWith('0x',[StringComparison]::OrdinalIgnoreCase)){$hresultBits=[Convert]::ToUInt32($hresultText.Substring(2),16)}
            else{$hresultValue=[int64]::Parse($hresultText,[Globalization.CultureInfo]::InvariantCulture);$hresultBits=[uint32]($hresultValue -band 4294967295)}
            $hresultHex='0x'+('{0:X8}' -f $hresultBits)
            $nativeMatch=[regex]::Match($nativeMessage,'Cannot resolve the Windows current folder for (?<folder>[^:]+): SHGetKnownFolderPath failed \(HRESULT (?<hresult>0x[0-9A-Fa-f]{8})\)\.')
            $nativeFolder=if($nativeMatch.Success){$nativeMatch.Groups['folder'].Value}else{'unparsed'}
            $nativeHresult=if($nativeMatch.Success){'0x'+$nativeMatch.Groups['hresult'].Value.Substring(2).ToUpperInvariant()}else{'unparsed'}
            $comparisonDetails.Add("PowerShell $($failure.folder)=$hresultHex; Rust $nativeFolder=$nativeHresult")
            if($nativeMatch.Success -and [string]::Equals($nativeFolder,$failure.folder,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($nativeHresult,$hresultHex,[StringComparison]::OrdinalIgnoreCase)){$matchingFailure=$true;break}
        }
        $details=($comparisonDetails -join '; ')
        Assert $matchingFailure ('Rust current-folder resolution did not match PowerShell when Windows could not resolve a Known Folder. '+$details)
        'PASS: Rust and PowerShell both fail closed for unavailable current Known Folder paths'
    }else{
        $nativeCurrent=(Invoke-Worker '{"version":1,"operation":"resolve"}')[0]
        Assert ($nativeCurrent.type -ceq 'resolved' -and $nativeCurrent.folders.Count -eq $expectedCurrent.Count) 'Rust current-folder lookup returned an incomplete set'
        foreach($expectedFolder in $expectedCurrent){
            $actualFolder=@($nativeCurrent.folders|Where-Object {$_.folder -ceq $expectedFolder.folder})
            Assert ($actualFolder.Count -eq 1 -and [string]::Equals($actualFolder[0].path,$expectedFolder.path,[StringComparison]::OrdinalIgnoreCase)) ('Rust current Known Folder API differs for '+$expectedFolder.folder)
        }
        'PASS: Rust current-folder paths match the Windows API for all available managed folders'
    }
    $checkRequest=@{version=1;operation='check';root=$fixture;include_music=$true}|ConvertTo-Json -Compress
    $checkRecords=Invoke-Worker $checkRequest
    $check=$checkRecords[0].check
    Assert ($checkRecords[0].type -ceq 'check' -and $check.registry_values.Count -eq $expected.Count) 'Read-only check omitted mapped registry aliases'
    Assert ($check.resolved_folders.Count -eq 7 -and $check.cloud_sync -ceq 'Not verified by this read-only check.') 'Read-only check omitted resolved folders or overstated cloud verification'
    $referenceCheck=@(& $module {param($root) Test-ICloudFolderSetup -ICloudRoot $root -IncludeMusic} $fixture)
    Assert ($check.root_exists -eq $referenceCheck.RootExists -and $check.root_registered -eq $referenceCheck.RootRegistered) 'Rust root existence or registration differs from the PowerShell checker'
    Assert ($check.user_sid -ceq $referenceCheck.UserSid) 'Rust current-user SID differs from the PowerShell checker'
    Assert ($check.registry_values.Count -eq $referenceCheck.RegistryValues.Count) 'Rust and PowerShell checker registry row counts differ'
    foreach($reference in $referenceCheck.RegistryValues){
        $actual=@($check.registry_values|Where-Object value_name -ceq $reference.ValueName)
        Assert ($actual.Count -eq 1 -and [string]::Equals($actual[0].current,$reference.Current,[StringComparison]::Ordinal) -and [string]::Equals($actual[0].expected,$reference.Expected,[StringComparison]::Ordinal) -and $actual[0].matches -eq $reference.Matches -and $actual[0].directory_exists -eq $reference.DirectoryExists) ('Rust registry check differs from PowerShell for '+$reference.Folder)
    }
    Assert ($check.registered_roots.Count -eq $referenceCheck.RegisteredRoots.Count) 'Rust and PowerShell checker registered-root counts differ'
    foreach($registered in $referenceCheck.RegisteredRoots){
        Assert (@($check.registered_roots|Where-Object {[string]::Equals($_,$registered,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1) 'Rust and PowerShell checker registered roots differ'
    }
    $registrationBasePath='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
    $registrationProbeId=[guid]::NewGuid().ToString('N')
    $registrationProviders=@(
        "iCloudDrive!CodexProbe-$registrationProbeId-a",
        "iCloudDrive!CodexProbe-$registrationProbeId-b",
        "icloudDrive!CodexProbe-$registrationProbeId-foreign",
        "iCloudDrive!CodexProbe-$registrationProbeId-malformed"
    )
    $registrationOwned=[Collections.Generic.List[string]]::new()
    $registrationBase=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($registrationBasePath,$true)
    Assert ($null -ne $registrationBase) 'Windows SyncRootManager registry key is unavailable on the isolated runner'
    try {
        foreach($providerName in $registrationProviders){
            $existing=$registrationBase.OpenSubKey($providerName)
            if($existing){$existing.Dispose();throw 'Generated SyncRootManager fixture key already exists; refusing to modify it'}
            $registrationOwned.Add($providerName)
        }
        $registrationRootA=Join-Path $fixture 'registered-root-a'
        $registrationRootB=Join-Path $fixture 'registered-root-b'
        $registrationRootForeign=Join-Path $fixture 'registered-root-foreign'
        $null=[IO.Directory]::CreateDirectory($registrationRootA)
        $null=[IO.Directory]::CreateDirectory($registrationRootB)
        $null=[IO.Directory]::CreateDirectory($registrationRootForeign)
        foreach($item in @(@($registrationProviders[0],$registrationRootA),@($registrationProviders[1],$registrationRootB))){
            $syncRoots=$registrationBase.CreateSubKey($item[0]+'\UserSyncRoots')
            try{$syncRoots.SetValue($sid,$item[1],[Microsoft.Win32.RegistryValueKind]::String)}finally{$syncRoots.Dispose()}
        }
        $foreignRoots=$registrationBase.CreateSubKey($registrationProviders[2]+'\UserSyncRoots')
        $sidParts=$sid -split '-'
        $currentRid=[UInt32]::Parse($sidParts[-1],[Globalization.CultureInfo]::InvariantCulture)
        $foreignRid=if($currentRid -eq [UInt32]::MaxValue){$currentRid-1}else{$currentRid+1}
        $foreignSid=($sidParts[0..($sidParts.Count-2)] -join '-')+'-'+$foreignRid
        try{$foreignRoots.SetValue($foreignSid,$registrationRootForeign,[Microsoft.Win32.RegistryValueKind]::String)}finally{$foreignRoots.Dispose()}

        $multiRootRequest=@{version=1;operation='check';root=$registrationRootA;include_music=$true}|ConvertTo-Json -Compress
        $multiRootCheck=(Invoke-Worker $multiRootRequest)[0].check
        $multiRootReference=& $module {param($root) Test-ICloudFolderSetup -ICloudRoot $root -IncludeMusic} $registrationRootA
        Assert ($multiRootCheck.root_registered -and $multiRootReference.RootRegistered) 'A current-SID Cloud Files root was not recognized'
        foreach($expectedRoot in @($registrationRootA,$registrationRootB)){
            Assert (@($multiRootCheck.registered_roots|Where-Object {[string]::Equals($_,$expectedRoot,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1) 'Rust registration enumeration omitted one of multiple current-SID roots'
            Assert (@($multiRootReference.RegisteredRoots|Where-Object {[string]::Equals($_,$expectedRoot,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1) 'PowerShell registration reference omitted one of multiple current-SID roots'
        }
        Assert (@($multiRootCheck.registered_roots|Where-Object {[string]::Equals($_,$registrationRootForeign,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0) 'Rust registration enumeration included a root belonging to another SID'
        Assert (@($multiRootReference.RegisteredRoots|Where-Object {[string]::Equals($_,$registrationRootForeign,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0) 'PowerShell registration reference included a root belonging to another SID'
        Assert ($multiRootCheck.registered_roots.Count -eq $multiRootReference.RegisteredRoots.Count) 'Rust and PowerShell registration counts differ with multiple provider entries'
        'PASS: native and PowerShell registration enumeration preserve multiple current-SID roots and ignore another SID'

        $malformedRoots=$registrationBase.CreateSubKey($registrationProviders[3]+'\UserSyncRoots')
        try{$malformedRoots.SetValue($sid,'relative-registration-path',[Microsoft.Win32.RegistryValueKind]::String)}finally{$malformedRoots.Dispose()}
        $malformedRequest=@{version=1;operation='check';root=$registrationRootA;include_music=$true}|ConvertTo-Json -Compress
        $malformedNative=Invoke-Worker $malformedRequest $false
        $malformedPowerShell=$false
        try{$null=& $module {param($root) Test-ICloudFolderSetup -ICloudRoot $root -IncludeMusic} $registrationRootA}catch{$malformedPowerShell=$true}
        Assert $malformedPowerShell 'PowerShell accepted a relative registered root in the malformed-path fixture'
        Assert ($malformedNative[-1].message) 'Rust failed without reporting the malformed registration path'
        'PASS: native registration enumeration refuses a malformed current-SID root like the PowerShell reference'
} catch {
    if($env:RUNNER_TEMP){
        $assertionPath=Join-Path $env:RUNNER_TEMP 'ICloudNativeBackendAssertion.txt'
        if(-not (Test-Path -LiteralPath $assertionPath)){
            $safeMessage=$_.Exception.Message
            if($safeMessage -like 'Unexpected result:*' -or $safeMessage -match '(?i)(?:[a-z]:\\|\\\\)'){
                $safeMessage='Guarded native backend validation failed; result or path details were withheld.'
            }
            $safeMessage=$safeMessage -replace '[\r\n]',' ' -replace '%','%25' -replace ':','%3A' -replace ',','%2C'
            [IO.File]::WriteAllText($assertionPath,$safeMessage,(New-Object Text.UTF8Encoding($false)))
        }
    }
    throw
} finally {
        try{foreach($providerName in $registrationOwned){$registrationBase.DeleteSubKeyTree($providerName,$false)}}finally{$registrationBase.Dispose()}
    }
    Assert ($check.errors.Count -eq $referenceCheck.Errors.Count) 'Rust and PowerShell checker error counts differ'
    Assert ($check.healthy -eq $referenceCheck.Healthy) 'Rust and PowerShell checker health results differ'
    $withoutMusicRequest=@{version=1;operation='check';root=$fixture;include_music=$false}|ConvertTo-Json -Compress
    $withoutMusic=(Invoke-Worker $withoutMusicRequest)[0].check
    Assert (@($withoutMusic.registry_values|Where-Object folder -ceq 'Music').Count -eq 0 -and @($withoutMusic.resolved_folders|Where-Object folder -ceq 'Music').Count -eq 0) 'A check that omits Music still returned Music rows'
    Assert ($withoutMusic.resolved_folders.Count -eq 6) 'A check without Music did not resolve all six required folders'
    $shellResolved=@(& $module {
        $map=Get-FolderMap -IncludeMusic
        foreach($folder in @($map.Values|Select-Object -Unique)){
            [pscustomobject]@{folder=$folder;path=(Get-ResolvedFolderPath $folder)}
        }
    })
    foreach($reference in $shellResolved){
        $actual=@($check.resolved_folders|Where-Object folder -ceq $reference.folder)
        Assert ($actual.Count -eq 1 -and [string]::Equals($actual[0].current,$reference.path,[StringComparison]::OrdinalIgnoreCase)) ('Rust configuration check differs from the PowerShell checker resolution for '+$reference.folder)
    }
    foreach($reference in $referenceCheck.ResolvedFolders){
        $actual=@($check.resolved_folders|Where-Object folder -ceq $reference.Folder)
        Assert ($actual.Count -eq 1 -and [string]::Equals($actual[0].current,$reference.Current,[StringComparison]::Ordinal) -and [string]::Equals($actual[0].expected,$reference.Expected,[StringComparison]::Ordinal) -and $actual[0].matches -eq $reference.Matches) ('Rust resolved-folder check differs from PowerShell for '+$reference.Folder)
    }
    $beforeSetupPreview=(Invoke-Worker '{"version":1,"operation":"backup_snapshot","include_music":true}')[0].backup.Values|ConvertTo-Json -Depth 6 -Compress
    $setupRequest=@{version=1;operation='setup_preview';root=$fixture;include_music=$true}|ConvertTo-Json -Compress
    $setupPreviewRecords=Invoke-Worker $setupRequest
    $setupPreview=$setupPreviewRecords[0].preview
    Assert ($setupPreviewRecords[0].type -ceq 'folder_preview' -and $setupPreview.operation -ceq 'setup') 'Rust did not return a setup preview'
    Assert ($setupPreview.rows.Count -eq $expected.Count -and $setupPreview.root -ceq $fixture) 'Rust setup preview omitted mapped folders or changed the selected root'
    Assert (-not $setupPreview.review_gates_passed) 'An unregistered temporary root passed the setup review gates'
    foreach($item in $expected){Assert (-not(Test-Path -LiteralPath (Join-Path $fixture $item.relative_path))) ('Setup preview created a destination: '+$item.relative_path)}
    $afterSetupPreview=(Invoke-Worker '{"version":1,"operation":"backup_snapshot","include_music":true}')[0].backup.Values|ConvertTo-Json -Depth 6 -Compress
    Assert ($beforeSetupPreview -ceq $afterSetupPreview) 'Setup preview changed current-user folder registry values'
    'PASS: setup preview returns every mapped destination, preserves review gates and creates or changes nothing'
    $custom=Join-Path $fixture 'CustomDocuments'
    $customRequest=@{version=1;operation='check';root=$fixture;include_music=$true;folder_paths=@{Documents=$custom}}|ConvertTo-Json -Compress
    $customCheck=(Invoke-Worker $customRequest)[0].check
    Assert (($customCheck.registry_values|Where-Object value_name -eq 'Personal'|Select-Object -First 1).expected -ceq $custom) 'Custom check path was not applied to the canonical Documents alias'
    $outsideRequest=@{version=1;operation='check';root=$fixture;include_music=$true;folder_paths=@{Documents=(Join-Path ([IO.Path]::GetTempPath()) 'outside')}}|ConvertTo-Json -Compress
    $outsideFailure=Invoke-Worker $outsideRequest $false
    Assert ($outsideFailure[-1].message -like '*inside the selected iCloud Drive folder*') 'Read-only check accepted a custom folder outside its root'
    $previewOutside=@{version=1;operation='setup_preview';root=$fixture;folder_paths=@{Documents=(Join-Path ([IO.Path]::GetTempPath()) 'outside')}}|ConvertTo-Json -Compress
    $previewOutsideFailure=Invoke-Worker $previewOutside $false
    Assert ($previewOutsideFailure[-1].message -like '*inside the selected iCloud Drive folder*') 'Setup preview accepted a custom path outside its root'
    if($defaultQueryError){
        $resetPreviewFailure=Invoke-Worker '{"version":1,"operation":"reset_preview"}' $false
        Assert ($resetPreviewFailure[-1].message -like '*SHGetKnownFolderPath failed*HRESULT*') 'Reset preview did not fail closed when Windows supplied no default paths'
    }
    'PASS: configuration check matches PowerShell paths, registry state, SID, registration and health; custom paths stay contained'
    $sid=[string](& $module { Get-UserSid })
    $backupKey='Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $backupBase=[pscustomobject]@{
        Version=1;Sid=$sid;Key=$backupKey;CreatedUtc=[DateTime]::UtcNow.ToString('o');Extension='ignored like PowerShell'
        Values=@(
            [pscustomobject]@{Name='Personal';Exists=$true;Kind='ExpandString';Data='C:\Users\Fixture\Documents';Extension=42},
            [pscustomobject]@{Name='{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}';Exists=$false;Kind=$null;Data=$null}
        )
    }
    $backupCases=[Collections.Generic.List[object]]::new()
    $backupCases.Add($backupBase)
    $duplicateBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress)
    $duplicateBackup.Values=@($duplicateBackup.Values)+@([pscustomobject]@{Name='personal';Exists=$false;Kind=$null;Data=$null})
    $backupCases.Add($duplicateBackup)
    $wrongSidBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress);$wrongSidBackup.Sid='S-1-5-21-999'
    $backupCases.Add($wrongSidBackup)
    $wrongKeyBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress);$wrongKeyBackup.Key='Software\Other'
    $backupCases.Add($wrongKeyBackup)
    $badKindBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress);$badKindBackup.Values[0].Kind='Binary'
    $backupCases.Add($badKindBackup)
    $badPathBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress);$badPathBackup.Values[0].Data='C:\'
    $backupCases.Add($badPathBackup)
    $absentDataBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress);$absentDataBackup.Values[1].Data='C:\Users\Fixture\Downloads'
    $backupCases.Add($absentDataBackup)
    foreach($candidate in $backupCases){
        $powerShellValid=$true
        try { & $module {param($record) Assert-Backup $record} $candidate } catch { $powerShellValid=$false }
        $backupRequest=([ordered]@{version=1;operation='validate_backup';backup=$candidate}|ConvertTo-Json -Depth 7 -Compress)
        $nativeRecords=Invoke-Worker $backupRequest $powerShellValid
        if($powerShellValid){Assert ($nativeRecords[0].type -ceq 'backup_validation' -and $nativeRecords[0].valid -and $nativeRecords[0].value_count -eq $candidate.Values.Count) 'Rust backup validator returned an incomplete success'}
    }
    $mixedCaseBackupJson=$backupBase|ConvertTo-Json -Depth 6 -Compress
    foreach($propertyCase in @(@('"Version"','"vErSiOn"'),@('"Sid"','"sID"'),@('"Key"','"kEy"'),@('"CreatedUtc"','"cReAtEdUtC"'),@('"Values"','"vAlUeS"'),@('"Name"','"nAmE"'),@('"Exists"','"eXiStS"'),@('"Kind"','"kInD"'),@('"Data"','"dAtA"'))){$mixedCaseBackupJson=$mixedCaseBackupJson.Replace($propertyCase[0],$propertyCase[1])}
    $mixedCaseRequest='{"version":1,"operation":"validate_backup","backup":'+$mixedCaseBackupJson+'}'
    $mixedCaseResult=(Invoke-Worker $mixedCaseRequest)[0]
    Assert ($mixedCaseResult.valid -and $mixedCaseResult.value_count -eq $backupBase.Values.Count) 'Rust backup validator did not match PowerShell case-insensitive property lookup'
    $settingsMutex=New-Object Threading.Mutex($false,('Local\ICloudFolders-'+$sid))
    $ownsSettingsMutex=$false
    try {
        $ownsSettingsMutex=$settingsMutex.WaitOne(0)
        Assert $ownsSettingsMutex 'Could not acquire the disposable account mutex fixture'
        $busySnapshot=Invoke-Worker '{"version":1,"operation":"backup_snapshot"}' $false
        Assert ($busySnapshot[-1].message -like '*Another ICloudFolders operation is running for this user*') 'Rust did not refuse a registry snapshot while the matching account mutex was held'
    } finally {
        if($ownsSettingsMutex){$settingsMutex.ReleaseMutex()}
        $settingsMutex.Dispose()
    }
    'PASS: Rust registry reads share the PowerShell per-account mutex and fail fast while it is held'
    'PASS: Rust backup validation matches PowerShell casing and unknown-property behavior, plus duplicate, wrong-account/key, invalid-type/path and absent-value rules'
    $nativeBackup=(Invoke-Worker '{"version":1,"operation":"backup_snapshot","include_music":true}')[0].backup
    $powerShellBackup=& $module {
        $map=Get-FolderMap -IncludeMusic
        $values=@(foreach($name in $map.Keys){Read-FolderValue $name})
        [pscustomobject]@{Version=1;Sid=(Get-UserSid);Key=$script:ShellKey;Values=$values}
    }
    Assert ($nativeBackup.Version -eq 1 -and $nativeBackup.Sid -ceq $powerShellBackup.Sid -and $nativeBackup.Key -ceq $powerShellBackup.Key) 'Rust backup snapshot header differs from PowerShell'
    $createdUtc=[DateTime]::MinValue
    Assert ([DateTime]::TryParse([string]$nativeBackup.CreatedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$createdUtc) -and $createdUtc.Kind -eq [DateTimeKind]::Utc) 'Rust backup timestamp is not a valid UTC round-trip timestamp'
    Assert ($nativeBackup.Values.Count -eq $powerShellBackup.Values.Count) 'Rust backup snapshot omitted mapped registry aliases'
    foreach($expectedValue in $powerShellBackup.Values){
        $actualValue=@($nativeBackup.Values|Where-Object Name -ceq $expectedValue.Name)
        Assert ($actualValue.Count -eq 1 -and $actualValue[0].Exists -eq $expectedValue.Exists -and [string]::Equals($actualValue[0].Kind,$expectedValue.Kind,[StringComparison]::Ordinal) -and [string]::Equals($actualValue[0].Data,$expectedValue.Data,[StringComparison]::Ordinal)) ('Rust backup snapshot differs for mapped value '+$expectedValue.Name)
    }
    $standardSnapshot=(Invoke-Worker '{"version":1,"operation":"backup_snapshot"}')[0].backup
    $standardNames=@(& $module { (Get-FolderMap).Keys })
    Assert ($standardSnapshot.Values.Count -eq $standardNames.Count -and @($standardSnapshot.Values|Where-Object {$_.Name -like '*Music*' -or $_.Name -eq '{A0C69A99-21C8-4671-8703-7934162FCF1D}'}).Count -eq 0) 'Default backup snapshot did not preserve the optional Music scope'
    $snapshotValidation=Invoke-Worker (([ordered]@{version=1;operation='validate_backup';backup=$nativeBackup}|ConvertTo-Json -Depth 7 -Compress))
    Assert ($snapshotValidation[0].valid -and $snapshotValidation[0].value_count -eq $powerShellBackup.Values.Count) 'Rust did not accept its complete current-account backup snapshot'
    'PASS: direct Win32 snapshot preserves every current mapped value and validates without writing a backup file'
    $restoreTarget=Join-Path $fixture ('restore-'+[char]0x00e9)
    $null=[IO.Directory]::CreateDirectory($restoreTarget)
    $restoreBackup=ConvertFrom-Json ($backupBase|ConvertTo-Json -Depth 6 -Compress)
    $restoreBackup.Values[0].Kind='String';$restoreBackup.Values[0].Data=$restoreTarget
    $restoreFile=Join-Path $fixture 'restore-before.json'
    $restoreBackup|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $restoreFile -Encoding UTF8
    $restoreFileHashBefore=(Get-FileHash -LiteralPath $restoreFile -Algorithm SHA256).Hash
    & $module {param($path) Invoke-ICloudFolders -RestoreBackup $path} $restoreFile *> $null
    $restoreRequest=([ordered]@{version=1;operation='restore_preview';backup=$restoreBackup}|ConvertTo-Json -Depth 7 -Compress)
    $restorePreview=(Invoke-Worker $restoreRequest)[0].preview
    Assert ($restorePreview.operation -ceq 'restore' -and $restorePreview.rows.Count -eq 2) 'Rust restore preview did not preserve the selected backup scope'
    $restoreFileRequest=([ordered]@{version=1;operation='restore_preview_file';path=$restoreFile}|ConvertTo-Json -Compress)
    $restoreFilePreview=(Invoke-Worker $restoreFileRequest)[0].preview
    Assert ($restoreFilePreview.operation -ceq 'restore' -and $restoreFilePreview.rows.Count -eq $restorePreview.rows.Count) 'Rust file-based restore preview did not read the synthetic PowerShell recovery file'
    Assert ((Get-FileHash -LiteralPath $restoreFile -Algorithm SHA256).Hash -ceq $restoreFileHashBefore) 'Rust restore-file preview changed its selected recovery file'
    foreach($desired in $restoreBackup.Values){
        $before=& $module {param($name) Read-FolderValue $name} $desired.Name
        $action=if(-not $desired.Exists){'Remove value'}elseif(-not $before.Exists){'Add missing value'}elseif($before.Data -ceq $desired.Data -and $before.Kind -ceq $desired.Kind){'Already configured'}else{'Update value'}
        $row=@($restorePreview.rows|Where-Object value_name -ceq $desired.Name)
        Assert ($row.Count -eq 1 -and $row[0].action -ceq $action -and $row[0].proposed_exists -eq $desired.Exists -and [string]::Equals($row[0].proposed,$desired.Data,[StringComparison]::Ordinal) -and [string]::Equals($row[0].proposed_kind,$desired.Kind,[StringComparison]::Ordinal)) 'Rust restore preview differs from PowerShell exact-value/action rules'
        $fileRow=@($restoreFilePreview.rows|Where-Object value_name -ceq $desired.Name)
        Assert ($fileRow.Count -eq 1 -and $fileRow[0].action -ceq $row[0].action -and [string]::Equals($fileRow[0].proposed,$row[0].proposed,[StringComparison]::Ordinal) -and [string]::Equals($fileRow[0].proposed_kind,$row[0].proposed_kind,[StringComparison]::Ordinal)) 'Rust file-based and in-memory restore previews differ'
    }
    'PASS: bounded Rust recovery-file preview matches the PowerShell BOM/Unicode synthetic record'
    $restoreBackup.Values[0].Data=Join-Path $fixture 'unavailable-restore-target'
    $restoreFailure=Invoke-Worker (([ordered]@{version=1;operation='restore_preview';backup=$restoreBackup}|ConvertTo-Json -Depth 7 -Compress)) $false
    Assert ($restoreFailure[-1].message -like '*Restore destination is unavailable*') 'Rust restore preview accepted an unavailable destination'
    $afterRestore=(Invoke-Worker '{"version":1,"operation":"backup_snapshot","include_music":true}')[0].backup
    Assert (($afterRestore.Values|ConvertTo-Json -Depth 6 -Compress) -ceq ($nativeBackup.Values|ConvertTo-Json -Depth 6 -Compress)) 'Read-only restore previews changed mapped registry values'
    'PASS: restore preview matches exact PowerShell types/actions, preserves absent-value removals and refuses unavailable destinations without writes'
    foreach($request in @('{"version":2,"operation":"metadata"}','{"version":1,"operation":"apply"}','{"version":1,"operation":"metadata","apply":true}','{"version":1,"operation":"plan","source":"relative","destination":"also-relative"}',(' '*65537))){$null=Invoke-Worker $request $false}
    'PASS: bounded protocol refuses unsupported versions, unknown fields and mutation requests'
    $source=Join-Path $fixture 'source';$target=Join-Path $fixture 'target'
    $null=[IO.Directory]::CreateDirectory((Join-Path $source 'empty'))
    $file=Join-Path $source ('unicode '+[char]0x00e9+' !.txt')
    [IO.File]::WriteAllText($file,'native fixture')
    $request=@{version=1;operation='plan';source=$source;destination=$target}|ConvertTo-Json -Compress
    $records=Invoke-Worker $request
    $entries=@($records | Where-Object type -eq 'entry' | ForEach-Object {$_.entry})
    Assert ($entries.Count -eq 3) 'Plan lost a directory or Unicode file'
    $entry=@($entries|Where-Object {-not $_.directory})[0]
    Assert ($entry.hash -ceq (Get-FileHash -LiteralPath $file).Hash) 'Native SHA-256 differs'
    Assert (-not(Test-Path -LiteralPath $target)) 'Read-only plan created destination'
    Assert ([IO.File]::ReadAllText($file) -ceq 'native fixture') 'Source changed'
    $copyModule=Import-Module (Join-Path $repo 'ICloudFolderCopy.psm1') -Force -PassThru
    $reference=@(& $copyModule {param($s,$d) Get-CopyPlan -Pairs @([pscustomobject]@{Source=$s;Destination=$d})} $source $target)
    Assert ($reference.Count -eq $entries.Count) 'Native and PowerShell plan counts differ'
    foreach($expectedEntry in $reference){
        $match=@($entries|Where-Object {$_.source -ceq $expectedEntry.Source -and $_.destination -ceq $expectedEntry.Destination})
        Assert ($match.Count -eq 1 -and $match[0].directory -eq $expectedEntry.Directory -and $match[0].hash -ceq $expectedEntry.Hash) 'Native plan differs from the PowerShell fixture reference'
    }
    $accountCloudRoot=Join-Path $env:USERPROFILE 'iCloudDrive'
    if(Test-Path -LiteralPath $accountCloudRoot -PathType Container){
        $pairRequest=@{version=1;operation='copy_pairs';root=$accountCloudRoot;include_music=$true}|ConvertTo-Json -Compress
        $nativePairs=@((Invoke-Worker $pairRequest)[0].pairs)
        $powerShellPairs=@(& $copyModule {param($root) Get-CopyPairs -ICloudRoot $root -IncludeMusic} $accountCloudRoot)
        Assert ($nativePairs.Count -eq $powerShellPairs.Count) 'Rust registry-derived copy-pair count differs from PowerShell'
        foreach($expectedPair in $powerShellPairs){
            $match=@($nativePairs|Where-Object {$_.source -ceq $expectedPair.Source -and $_.destination -ceq $expectedPair.Destination})
            Assert ($match.Count -eq 1) 'Rust registry-derived copy pair differs from PowerShell'
        }
        'PASS: direct Win32 registry-derived copy pairs match PowerShell without scanning source files'
    }else{'SKIP: account iCloud root is unavailable for read-only copy-pair parity'}
    $multiA=Join-Path $fixture 'multi-a';$multiB=Join-Path $fixture 'multi-b';$multiTarget=Join-Path $fixture 'multi-target'
    $null=[IO.Directory]::CreateDirectory($multiA);$null=[IO.Directory]::CreateDirectory($multiB)
    [IO.File]::WriteAllText((Join-Path $multiA 'same.txt'),'same source bytes')
    [IO.File]::WriteAllText((Join-Path $multiB 'same.txt'),'same source bytes')
    $pairs=@([pscustomobject]@{Source=$multiA;Destination=$multiTarget},[pscustomobject]@{Source=$multiB;Destination=$multiTarget})
    $manyRequest=@{version=1;operation='plan_many';pairs=@(@{source=$multiA;destination=$multiTarget},@{source=$multiB;destination=$multiTarget})}|ConvertTo-Json -Compress
    $manyRecords=Invoke-Worker $manyRequest
    $manyEntries=@($manyRecords|Where-Object type -eq 'entry'|ForEach-Object {$_.entry})
    $manyReference=@(& $copyModule {param($pairs) Get-CopyPlan -Pairs $pairs} $pairs)
    Assert ($manyEntries.Count -eq $manyReference.Count -and $manyEntries.Count -eq 2) 'Multi-source planning did not deduplicate identical destination entries like PowerShell'
    foreach($expectedEntry in $manyReference){
        $match=@($manyEntries|Where-Object {$_.source -ceq $expectedEntry.Source -and $_.destination -ceq $expectedEntry.Destination})
        Assert ($match.Count -eq 1 -and $match[0].directory -eq $expectedEntry.Directory -and $match[0].hash -ceq $expectedEntry.Hash) 'Multi-source Rust plan differs from the PowerShell fixture reference'
    }
    [IO.File]::WriteAllText((Join-Path $multiB 'same.txt'),'different bytes')
    $manyConflict=Invoke-Worker $manyRequest $false
    Assert (@($manyConflict|Where-Object type -eq 'entry').Count -eq 0) 'Multi-source conflict leaked partial entries before full preflight'
    $crossSource=Join-Path $fixture 'cross-source';$crossNested=Join-Path $crossSource 'nested'
    $null=[IO.Directory]::CreateDirectory($crossNested)
    $crossRequest=@{version=1;operation='plan_many';pairs=@(@{source=$crossSource;destination=$crossNested},@{source=$crossNested;destination=(Join-Path $fixture 'cross-target')})}|ConvertTo-Json -Compress
    $crossFailure=Invoke-Worker $crossRequest $false
    Assert ($crossFailure[-1].message -like '*trees overlap*' -and @($crossFailure|Where-Object type -eq 'entry').Count -eq 0) 'Multi-source cross-pair overlap was not rejected before output'
    'PASS: single- and multi-source plans match PowerShell deduplication; multi-source conflicts emit no partial plan'
    $null=[IO.Directory]::CreateDirectory($target)
    Copy-Item -LiteralPath $file -Destination $target
    $records=Invoke-Worker $request
    Assert (@($records|Where-Object {$_.type -eq 'entry' -and $_.entry.action -eq 'SkipIdentical'}).Count -eq 1) 'Identical file was not skipped'
    [IO.File]::WriteAllText((Join-Path $target ([IO.Path]::GetFileName($file))),'conflict')
    $null=Invoke-Worker $request $false
    Assert ([IO.File]::ReadAllText((Join-Path $target ([IO.Path]::GetFileName($file)))) -ceq 'conflict') 'Conflict content changed'
    Assert (-not(Test-Path -LiteralPath (Join-Path $target 'empty'))) 'Failed plan created a directory'
    $overlap=@{version=1;operation='plan';source=$source;destination=(Join-Path $source 'nested')}|ConvertTo-Json -Compress
    $null=Invoke-Worker $overlap $false
    'PASS: identical skip, destination conflicts and overlapping trees are handled without writes'
    $link=Join-Path $source 'junction'
    Copy-Item -LiteralPath $file -Destination $target -Force
    $null=New-Item -ItemType Junction -Path $link -Target $target
    try{
        $failure=Invoke-Worker $request $false
        Assert ($failure[-1].message -like '*not supported by this prototype*') 'Junction refusal failed for an unrelated reason'
    }finally{[IO.Directory]::Delete($link)}
    $deep=Join-Path $fixture 'deep';$cursor=$deep
    foreach($i in 1..65){$cursor=Join-Path $cursor 'd'}
    $null=[IO.Directory]::CreateDirectory($cursor)
    $deepRequest=@{version=1;operation='plan';source=$deep;destination=(Join-Path $fixture 'deep-target')}|ConvertTo-Json -Compress
    $failure=Invoke-Worker $deepRequest $false
    Assert ($failure[-1].message -like '*planning limit reached*') 'Depth bound failed for an unrelated reason'
    Assert (-not(Test-Path -LiteralPath (Join-Path $fixture 'deep-target'))) 'Depth-limit refusal created a destination'
    # This is a read-only snapshot, not a synchronization-health check. Never print personal values.
    $inspection=Invoke-Worker '{"version":1,"operation":"inspect"}'
    Assert ($inspection[0].values.Count -eq $expected.Count) 'Registry inspection lost mapped aliases'
    'PASS: junction refusal and read-only registry inspection'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ICloudNativeFixture-[a-f0-9]{32}$'){throw 'Refusing cleanup outside the native fixture'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
