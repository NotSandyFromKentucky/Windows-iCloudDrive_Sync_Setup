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
