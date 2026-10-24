#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('.test-copy-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Fail([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action}catch{$message=$_.Exception.Message};Assert ($message -like ('*'+$Pattern+'*')) ("Expected "+$Pattern+"; got "+$message)}
$module=Import-Module (Join-Path $repo 'ICloudFolderCopy.psm1') -Force -PassThru
try{
    $source=Join-Path $fixture 'source';$target=Join-Path $fixture 'destination'
    $null=[IO.Directory]::CreateDirectory((Join-Path $source 'empty'))
    [IO.File]::WriteAllText((Join-Path $source 'a.txt'),'original')
    [IO.File]::WriteAllText((Join-Path $source ('special ! '+[char]0x00E9+'.txt')),'unicode path')
    & $module {param($Source,$Target) $script:Pairs=@([pscustomobject]@{Source=$Source;Destination=$Target});function script:Get-CopyPairs { $script:Pairs }} $source $target
    $channel='Local\ICloudCopy-'+[guid]::NewGuid().ToString('N')
    $cancel=New-Object Threading.EventWaitHandle($true,[Threading.EventResetMode]::ManualReset,$channel)
    try{Fail {Invoke-ICloudFolderCopy -Apply -CancelEventName $channel} 'safe boundary'}finally{$cancel.Dispose()}
    Assert (-not(Test-Path -LiteralPath $target)) 'Pre-signalled stop created destination'
    Fail {Invoke-ICloudFolderCopy -CancelEventName 'invalid'} 'Invalid cancellation channel'
    'PASS: cancellation during planning and invalid channels cannot write destination files'
    Invoke-ICloudFolderCopy
    Invoke-ICloudFolderCopy -Apply -WhatIf
    Assert (-not(Test-Path -LiteralPath $target)) 'Preview or WhatIf created destination'
    'PASS: copy preview and WhatIf create no files or directories'
    Invoke-ICloudFolderCopy -Apply
    Assert ([IO.File]::ReadAllText((Join-Path $source 'a.txt')) -ceq 'original') 'Source content changed'
    Assert ((Get-FileHash (Join-Path $source 'a.txt')).Hash -ceq (Get-FileHash (Join-Path $target 'a.txt')).Hash) 'Copied content differs'
    Assert (Test-Path (Join-Path $target 'empty') -PathType Container) 'Empty directory lost'
    Assert (@(Get-ChildItem $target -File).Count -eq 2) 'Unicode file lost'
    Invoke-ICloudFolderCopy -Apply
    Assert (@(Get-ChildItem $target -File).Count -eq 2) 'Identical rerun duplicated files'
    'PASS: copy verifies contents, preserves sources and empty folders, and skips identical files'
    [IO.File]::WriteAllText((Join-Path $target 'a.txt'),'different')
    [IO.File]::WriteAllText((Join-Path $source 'new.txt'),'new')
    Fail {Invoke-ICloudFolderCopy -Apply} 'nothing will be overwritten'
    Assert (-not(Test-Path (Join-Path $target 'new.txt'))) 'Conflict allowed partial preflight writes'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'a.txt')) -ceq 'different') 'Conflict overwritten'
    'PASS: different same-name files block the complete plan before writes'
    & $module {param($Source) $script:Pairs=@([pscustomobject]@{Source=$Source;Destination=(Join-Path $Source 'nested')})} $source
    Fail {Invoke-ICloudFolderCopy -Apply} 'overlap'
    Assert (-not(Test-Path (Join-Path $source 'nested'))) 'Nested destination created'
    'PASS: overlapping source/destination trees are rejected'
    $source2=Join-Path $fixture 'other-source';$null=[IO.Directory]::CreateDirectory($source2)
    [IO.File]::WriteAllText((Join-Path $source2 'a.txt'),'second different source')
    $target2=Join-Path $fixture 'merge-target'
    & $module {param($A,$B,$Target) $script:Pairs=@([pscustomobject]@{Source=$A;Destination=$Target},[pscustomobject]@{Source=$B;Destination=$Target})} $source $source2 $target2
    Fail {Invoke-ICloudFolderCopy -Apply} 'Different source files'
    Assert (-not(Test-Path $target2)) 'Multi-source conflict wrote files'
    'PASS: mismatched aliases cannot silently choose one file to keep'
    $link=Join-Path $fixture 'junction'
    $null=New-Item -ItemType Junction -Path $link -Target $source
    & $module {param($Link,$Target) $script:Pairs=@([pscustomobject]@{Source=$Link;Destination=$Target})} $link $target2
    Fail {Invoke-ICloudFolderCopy -Apply} 'refuses links'
    'PASS: junctions are not followed'
    # Remove only the test junction itself before recursive fixture cleanup.
    [IO.Directory]::Delete($link)
    & $module {
        param($Source,$Target)
        $script:Pairs=@([pscustomobject]@{Source=$Source;Destination=$Target})
        $script:OriginalHash=(Get-Item Function:Get-CopyHash).ScriptBlock
        $script:HashCalls=0
        function script:Get-CopyHash {
            param($Path)
            $script:HashCalls++
            if($script:HashCalls -eq 8){throw 'Injected read failure'}
            & $script:OriginalHash $Path
        }
    } $source $target2
    Fail {Invoke-ICloudFolderCopy -Apply} 'Injected read failure'
    Assert ([IO.File]::ReadAllText((Join-Path $source 'a.txt')) -ceq 'original') 'Failure changed source'
    Assert (Test-Path (Join-Path $target2 'a.txt')) 'Partial-copy failure fixture did not exercise a completed destination write'
    'PASS: partial-copy failures retain originals and completed destination files for inspection'
    # Change real fixture content exactly between the initial and fresh plans.
    # Every case must stop before creating any destination directory/file.
    $changes=@(
        @{Name='added source';Edit={param($S,$T) [IO.File]::WriteAllText((Join-Path $S 'new.txt'),'new')}},
        @{Name='changed source';Edit={param($S,$T) [IO.File]::WriteAllText((Join-Path $S 'a.txt'),'changed')}},
        @{Name='removed source';Edit={param($S,$T) [IO.File]::Delete((Join-Path $S 'a.txt'))}},
        @{Name='renamed source';Edit={param($S,$T) [IO.File]::Move((Join-Path $S 'a.txt'),(Join-Path $S 'renamed.txt'))}},
        @{Name='source became directory';Edit={param($S,$T) $path=Join-Path $S 'a.txt';[IO.File]::Delete($path);$null=[IO.Directory]::CreateDirectory($path)}},
        @{Name='newly identical destination';Edit={param($S,$T) $null=[IO.Directory]::CreateDirectory($T);[IO.File]::WriteAllText((Join-Path $T 'a.txt'),'original')}}
    )
    foreach($change in $changes){
        $raceRoot=Join-Path $fixture ('replan-'+[guid]::NewGuid().ToString('N'))
        $raceSource=Join-Path $raceRoot 'source';$raceTarget=Join-Path $raceRoot 'destination'
        $null=[IO.Directory]::CreateDirectory($raceSource)
        [IO.File]::WriteAllText((Join-Path $raceSource 'a.txt'),'original')
        [IO.File]::WriteAllText((Join-Path $raceSource 'untouched.txt'),'retain this')
        $racePath=Join-Path $raceRoot 'RaceCopy.psm1'
        Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderCopy.psm1') -Destination $racePath
        $raceModule=Import-Module $racePath -Force -PassThru
        try{
            & $raceModule {
                param($S,$T,$Edit)
                $script:RaceSource=$S;$script:RaceTarget=$T;$script:Edit=$Edit;$script:PlanCalls=0
                $script:OriginalPlan=(Get-Item Function:Get-CopyPlan).ScriptBlock
                function script:Get-CopyPairs {[pscustomobject]@{Source=$script:RaceSource;Destination=$script:RaceTarget}}
                function script:Get-CopyPlan {
                    param([object[]]$Pairs)
                    $script:PlanCalls++
                    if($script:PlanCalls -eq 2){& $script:Edit $script:RaceSource $script:RaceTarget}
                    & $script:OriginalPlan $Pairs
                }
            } $raceSource $raceTarget $change.Edit
            Fail {& $raceModule {Invoke-ICloudFolderCopy -Apply}} 'Files changed after planning'
            Assert ([IO.File]::ReadAllText((Join-Path $raceSource 'untouched.txt')) -ceq 'retain this') 'Replan failure changed retained source content'
            Assert (-not(Test-Path (Join-Path $raceTarget 'untouched.txt'))) 'Replan drift allowed a destination copy'
            if($change.Name -ne 'newly identical destination'){Assert (-not(Test-Path $raceTarget)) 'Replan drift created a destination directory'}
        }finally{Remove-Module $raceModule -Force}
    }
    'PASS: source content/path/type changes and newly identical destinations invalidate the fresh plan before copying'
    & $module {
        $entry=[pscustomobject]@{Source=('C:\fixture\'+[char]0xE9);Destination='C:\target';Directory=$true;Hash=$null;Action='Copy'}
        $same=[pscustomobject]@{Source=$entry.Source;Destination=$entry.Destination;Directory=$true;Hash=$null;Action='Copy'}
        if(-not(Test-CopyPlansEqual @($entry) @($same))){throw 'Identical plans rejected'}
        $same.Hash=''
        if(Test-CopyPlansEqual @($entry) @($same)){throw 'Null and empty directory hashes compared equal'}
        $same.Hash=$null;$same.Source='C:\fixture\e'+[char]0x301
        if(Test-CopyPlansEqual @($entry) @($same)){throw 'Different Unicode path spellings compared equal'}
        $same.Source=$entry.Source.ToUpperInvariant()
        if(Test-CopyPlansEqual @($entry) @($same)){throw 'Case-only path changes compared equal'}
        $other=[pscustomobject]@{Source='C:\other';Destination='C:\target2';Directory=$false;Hash=('A'*64);Action='Copy'}
        if(Test-CopyPlansEqual @($entry,$other) @($other,$entry)){throw 'Reordered plans compared equal'}
    }
    'PASS: plan comparison preserves ordering, nullable hashes and exact Unicode path identity'
    $core=Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
    $cloud=Join-Path $fixture 'cloud';$null=[IO.Directory]::CreateDirectory($cloud)
    & $core {
        param($Root,$Source)
        $script:Root=$Root;$script:Source=$Source
        function script:Get-RegisteredICloudRoots {$script:Root}
        function script:Read-FolderValue {
            param($Name)
            [pscustomobject]@{Name=$Name;Exists=($Name -in @('Personal','{F42EE2D3-909F-4907-8871-4C22FC0BF756}'));Kind='ExpandString';Data=$script:Source}
        }
    } $cloud $source
    $pairPath=Join-Path $fixture 'PairCopy.psm1';Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderCopy.psm1') -Destination $pairPath
    $pairModule=Import-Module $pairPath -Force -PassThru
    try{
        & $pairModule {param($Core) $script:Core=$Core;function script:Import-Module {param($Name,[switch]$Force,[switch]$PassThru) $script:Core}} $core
        $custom=Join-Path $cloud 'Personal files'
        $pairs=@(& $pairModule {param($Root,$Custom) Get-CopyPairs -ICloudRoot $Root -FolderPaths @{Documents=$Custom} -ForApply} $cloud $custom)
        Assert ($pairs.Count -eq 1 -and $pairs[0].Destination -ceq $custom -and $pairs[0].Source -ceq $source) 'Copy targets differ from custom setup paths or aliases were not deduplicated.'
        Fail {& $pairModule {param($Custom) Get-CopyPairs -ResetToDefaults -FolderPaths @{Documents=$Custom}} $custom} 'cannot replace Windows defaults'
        'PASS: custom copy destinations reuse the central map, deduplicate aliases and cannot override reset defaults'
    }finally{Remove-Module $pairModule -Force;Remove-Module $core -Force}
    'All copy tests used isolated folders; no live folder settings or personal files were changed.'
}finally{
    Remove-Module $module -Force
    $full=[IO.Path]::GetFullPath($fixture)
    if($full.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\')+'\.test-copy-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $full -Recurse -Force}
}
