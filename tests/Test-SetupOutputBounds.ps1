#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'ICloudFolderSetup.UI.psm1') -Force -PassThru
try{
    & $module { Initialize-SetupOutputReader }
    function New-Reader([string]$Value){
        $bytes=[Text.Encoding]::UTF8.GetBytes($Value)
        $stream=[IO.MemoryStream]::new($bytes)
        [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,4096,$false)
    }
    function Assert($Condition,$Message){if(-not $Condition){throw $Message}}

    $builder=New-Object Text.StringBuilder
    for($index=0;$index -lt 5;$index++){$null=$builder.AppendLine(('a'*24000))}
    for($index=0;$index -lt 100;$index++){$null=$builder.AppendLine(('@@ICloudProgress:'+(@{Stage='Copying';File=('file-'+$index);Completed=$index;Total=100}|ConvertTo-Json -Compress)))}
    $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
    $reader=New-Reader $builder.ToString()
    try{$output=[ICloudSetup.LiveOutput]::Collect($reader,$queue).GetAwaiter().GetResult()}finally{$reader.Dispose()}
    Assert ($output.Length -le (64*1024+256) -and $output -like '*Output bounded*') 'stdout retention exceeded its character budget or omitted the summary marker'
    Assert ($queue.Count -eq 64) ('progress queue is not capped at 64 records: '+$queue.Count)
    $latest=$null;$next=$null;while($queue.TryDequeue([ref]$next)){$latest=$next}
    $latestEvent=$latest.Substring(17)|ConvertFrom-Json
    Assert ($latestEvent.Completed -eq 99) 'bounded progress queue discarded the newest progress update'
    'PASS: stdout summary and progress queue remain bounded while preserving the latest event'

    $longLine=('x'*70000)+' ROLLBACK INCOMPLETE'
    $lineReader=New-Reader $longLine
    try{$bounded=[ICloudSetup.BoundedLineReader]::new($lineReader,64*1024).ReadLineAsync().GetAwaiter().GetResult()}finally{$lineReader.Dispose()}
    Assert ($bounded.Length -le (64*1024+128) -and $bounded -like '*line truncated*' -and $bounded -like '*ROLLBACK INCOMPLETE*') 'oversized stdout line lost its bound or critical tail'
    'PASS: oversized stdout line retains its bounded prefix and critical tail'

    $errorValue=('e'*100000)+[Environment]::NewLine+'Recovery backup: C:\fixture\before.json'
    $errorReader=New-Reader $errorValue
    try{$errorText=[ICloudSetup.LiveOutput]::CollectErrors($errorReader).GetAwaiter().GetResult()}finally{$errorReader.Dispose()}
    Assert ($errorText.Length -le (64*1024+256) -and $errorText -like '*Output bounded*' -and $errorText -like '*C:\fixture\before.json*') 'stderr output exceeded its cap or lost the recovery path'
    'PASS: stderr summary retains the most recent recovery path within its bound'
}finally{Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
