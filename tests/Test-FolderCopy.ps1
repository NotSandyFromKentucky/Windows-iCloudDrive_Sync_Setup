#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$fixtureRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture=Join-Path $fixtureRoot ('.test-copy-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Fail([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action}catch{$message=$_.Exception.Message};Assert ($message -like ('*'+$Pattern+'*')) ("Expected "+$Pattern+"; got "+$message)}
$module=Import-Module (Join-Path $repo 'ICloudFolderCopy.psm1') -Force -PassThru
try{
    $throttle=& $module {
        $script:CopyProgressLastTimestamp=1000L;$script:CopyProgressLastStage='Verified'
        $step=[long][Math]::Max(1,[Diagnostics.Stopwatch]::Frequency/10)
        $suppressed=-not (Test-CopyProgressDue -Stage 'Verified' -Completed 2 -Total 10 -NowTicks (1000L+$step-1))
        $interval=Test-CopyProgressDue -Stage 'Verified' -Completed 3 -Total 10 -NowTicks (1000L+$step)
        $stage=Test-CopyProgressDue -Stage 'Copying and verifying' -Completed 3 -Total 10 -NowTicks (1000L+$step)
        $final=Test-CopyProgressDue -Stage 'Verified' -Completed 10 -Total 10 -NowTicks (1000L+$step)
        [pscustomobject]@{Suppressed=$suppressed;Interval=$interval;StageChange=$stage;Final=$final}
    }
    Assert ($throttle.Suppressed -and $throttle.Interval -and $throttle.StageChange -and $throttle.Final) 'Progress throttle failed its cadence, stage-change or final-update checks'
    'PASS: copy progress is limited to 10 Hz while stage changes and the final verification remain visible'
    $pageChecks=& $module {
        $items=New-Object 'Collections.Generic.List[object]'
        for($i=0;$i -lt 205;$i++){$items.Add([pscustomobject]@{Source=('C:\source\'+$i);Destination=('C:\target\'+$i);Directory=$false;Hash=([string]$i).PadLeft(64,'0');Action='Copy'})}
        $token=Get-CopyPlanToken $items
        $writer=New-Object IO.StringWriter;$original=[Console]::Out
        try{
            [Console]::SetOut($writer)
            Write-CopyPlanPage -Plan $items -Offset 0 -Token $token
            $firstJson=$writer.ToString().Trim();$first=ConvertFrom-Json ($firstJson.Substring(17))
            $firstBytes=[Text.Encoding]::UTF8.GetByteCount($firstJson.Substring(17))
            $writer.GetStringBuilder().Clear()|Out-Null
            Write-CopyPlanPage -Plan $items -Offset $first.NextOffset -Token $token
            $second=ConvertFrom-Json ($writer.ToString().Trim().Substring(17))
            $writer.GetStringBuilder().Clear()|Out-Null
            Write-CopyPlanPage -Plan $items -Offset $second.NextOffset -Token $token
            $last=ConvertFrom-Json ($writer.ToString().Trim().Substring(17))
        }finally{[Console]::SetOut($original);$writer.Dispose()}
        $oldHash=$items[0].Hash;$items[0].Hash='F'*64;$changed=(Get-CopyPlanToken $items) -cne $token
        $items[0].Hash=$oldHash
        [pscustomobject]@{TokenValid=($token -match '^[a-f0-9]{64}$');ChangedPlanRejected=($changed);ByteBound=($firstBytes -le 512*1024);First=($first.Offset -eq 0 -and @($first.Entries).Count -eq 100 -and $first.NextOffset -eq 100);Second=($second.Offset -eq 100 -and @($second.Entries).Count -eq 100 -and $second.NextOffset -eq 200);Last=($last.Offset -eq 200 -and @($last.Entries).Count -eq 5 -and $null -eq $last.NextOffset);Total=($first.TotalEntries -eq 205 -and $second.TotalEntries -eq 205 -and $last.TotalEntries -eq 205)}
    }
    Assert ($pageChecks.TokenValid -and $pageChecks.ChangedPlanRejected -and $pageChecks.ByteBound -and $pageChecks.First -and $pageChecks.Second -and $pageChecks.Last -and $pageChecks.Total) 'Bounded copy review pages or full-plan approval token validation failed'
    'PASS: copy review pages are bounded, complete, ordered and bound to the full plan'
    $largePage=& $module {
        $items=New-Object 'Collections.Generic.List[object]';$source='s'*40000;$destination='d'*40000
        for($i=0;$i -lt 10;$i++){$items.Add([pscustomobject]@{Source=$source;Destination=$destination;Directory=$false;Hash=('0'*64);Action='Copy'})}
        $writer=New-Object IO.StringWriter;$original=[Console]::Out
        try{[Console]::SetOut($writer);Write-CopyPlanPage -Plan $items -Offset 0 -Token ('a'*64);$line=$writer.ToString().Trim();$page=ConvertFrom-Json ($line.Substring(17));[pscustomobject]@{Count=@($page.Entries).Count;Next=$page.NextOffset;Bytes=[Text.Encoding]::UTF8.GetByteCount($line.Substring(17))}}
        finally{[Console]::SetOut($original);$writer.Dispose()}
    }
    Assert ($largePage.Count -gt 0 -and $largePage.Count -lt 10 -and $largePage.Next -eq $largePage.Count -and $largePage.Bytes -le 512*1024) 'Copy page did not stop at the UTF-8 byte budget'
    'PASS: page sizing follows UTF-8 bytes as well as row count'
    $oversized=[pscustomobject]@{Source=('a'*300000);Destination=('b'*300000);Directory=$false;Hash=('0'*64);Action='Copy'}
    Fail {& $module {param($Entry) Write-CopyPlanPage -Plan @($Entry) -Offset 0 -Token ('a'*64)} $oversized} 'single copy-review row exceeds the bounded page size'
    'PASS: a single oversized copy row fails closed'
    $source=Join-Path $fixture 'source';$target=Join-Path $fixture 'destination'
    $null=[IO.Directory]::CreateDirectory((Join-Path $source 'empty'))
    [IO.File]::WriteAllText((Join-Path $source 'a.txt'),'original')
    $hiddenSource=Join-Path $source 'hidden.txt'
    [IO.File]::WriteAllText($hiddenSource,'hidden source data')
    [IO.File]::SetAttributes($hiddenSource,[IO.FileAttributes]::Hidden)
    [IO.File]::WriteAllText((Join-Path $source ('special ! '+[char]0x00E9+'.txt')),'unicode path')
    & $module {param($Source,$Target) $script:Pairs=@([pscustomobject]@{Source=$Source;Destination=$Target});function script:Get-CopyPairs { $script:Pairs }} $source $target
    Fail {Invoke-ICloudFolderCopy -Apply -StructuredPage -ReviewToken ('0'*64)} 'Files changed after preview'
    Assert (-not(Test-Path -LiteralPath $target)) 'A mismatched full-plan review token allowed destination writes'
    'PASS: copy Apply rejects a stale or missing full-plan approval token before writes'
    $enumerationSource=Join-Path $fixture 'enumeration-source';$enumerationTarget=Join-Path $fixture 'enumeration-destination'
    $null=[IO.Directory]::CreateDirectory($enumerationSource)
    [IO.File]::WriteAllText((Join-Path $enumerationSource 'first.txt'),'enumeration fixture')
    $originalCancellation=& $module {(Get-Item Function:Test-CopyCancellation).ScriptBlock}
    & $module {
        param($Source,$Target)
        $script:Pairs=@([pscustomobject]@{Source=$Source;Destination=$Target})
        $script:EnumerationCancellationChecks=0
        function script:Get-CopyPairs {$script:Pairs}
        function script:Test-CopyCancellation {
            $script:EnumerationCancellationChecks++
            if($script:EnumerationCancellationChecks -eq 2){throw (New-Object OperationCanceledException('Injected cancellation during child enumeration.'))}
        }
    } $enumerationSource $enumerationTarget
    try{
        Fail {Invoke-ICloudFolderCopy -Apply} 'Injected cancellation during child enumeration'
        Assert ((& $module {$script:EnumerationCancellationChecks}) -eq 2) 'Cancellation was not checked after the enumerator yielded a child.'
        Assert (-not(Test-Path -LiteralPath $enumerationTarget)) 'Mid-enumeration cancellation wrote destination files.'
    }finally{& $module {param($Original,$Source,$Target) Set-Item Function:script:Test-CopyCancellation -Value $Original;$script:Pairs=@([pscustomobject]@{Source=$Source;Destination=$Target})} $originalCancellation $source $target}
    'PASS: cancellation is polled while lazily enumerating directory children'
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
    Assert ([IO.File]::ReadAllText((Join-Path $target 'hidden.txt')) -ceq 'hidden source data') 'Hidden source file was omitted'
    Assert (Test-Path (Join-Path $target 'empty') -PathType Container) 'Empty directory lost'
    Assert (@(Get-ChildItem $target -Force -File).Count -eq 3) 'Unicode or hidden file lost'
    Invoke-ICloudFolderCopy -Apply
    Assert (@(Get-ChildItem $target -Force -File).Count -eq 3) 'Identical rerun duplicated files'
    'PASS: copy verifies contents, includes hidden files, preserves sources and empty folders, and skips identical files'
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
        $script:FailAt=2*@([IO.Directory]::EnumerateFiles($Source)).Count+2
        function script:Get-CopyHash {
            param($Path)
            $script:HashCalls++
            if($script:HashCalls -eq $script:FailAt){throw 'Injected read failure'}
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
                    param([object[]]$Pairs,[switch]$PreserveList,[Collections.IList]$ExpectedPlan,[switch]$CompareExpectedPlan)
                    $script:PlanCalls++
                    if($script:PlanCalls -eq 2){& $script:Edit $script:RaceSource $script:RaceTarget}
                    & $script:OriginalPlan -Pairs $Pairs -PreserveList:$PreserveList -ExpectedPlan $ExpectedPlan -CompareExpectedPlan:$CompareExpectedPlan
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
    if($full.StartsWith($fixtureRoot+'\.test-copy-',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^\.test-copy-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
