using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace ICloudFolderSetup;

public sealed record SetupOptions(string Action,string Root,string Backup,bool Music,bool Verified,bool KeepFiles,bool Json,bool DesktopShortcut=false,string FolderPathsJson="")
{
    public bool IsCopy => Action.StartsWith("Copy files",StringComparison.Ordinal);
    public bool Mutates => !Action.StartsWith("Check",StringComparison.Ordinal);
    public string CommitLabel => Action switch {
        var a when a.StartsWith("Copy") => "Copy files",
        var a when a.StartsWith("Reset") => "Reset locations",
        var a when a.StartsWith("Restore") => "Restore locations",
        var a when a.StartsWith("Create") => "Create test file",
        var a when a.StartsWith("Clean") => "Remove test file",
        _ => "Change locations"
    };
}
public sealed record OperationResult(int ExitCode,string Message,string Text,CopyReviewPage? CopyPage=null,int Version=0,bool TextTruncated=false,long CapturedCharacters=0);
public sealed record CopyProgress(string Stage,string File,int Completed,int Total);
public sealed record CopyPlanRow(string Source,string Destination,bool Directory,string Action);
public sealed record CopyReviewPage(int Version,string Type,string ApprovalToken,int Offset,int? NextOffset,int TotalEntries,CopyPlanRow[] Entries);
public sealed record FolderDefinition(string Id,string RelativePath);
internal sealed record BoundedProtocolLine(string Text,bool Overflow);
internal sealed class BoundedProtocolReader(StreamReader reader,int maximumCharacters)
{
    private readonly char[] buffer=new char[4096];
    private int offset;
    private int length;

    public async Task<BoundedProtocolLine?> ReadLineAsync()
    {
        var value=new StringBuilder(Math.Min(maximumCharacters,4096));
        var overflow=false;
        var sawCharacter=false;
        while(true){
            if(offset>=length){
                length=await reader.ReadAsync(buffer.AsMemory(0,buffer.Length)).ConfigureAwait(false);
                offset=0;
                if(length==0)return sawCharacter ? Finish() : null;
            }
            char character=buffer[offset++];
            if(character=='\n')return Finish();
            sawCharacter=true;
            if(value.Length<maximumCharacters)value.Append(character);
            else overflow=true;
        }

        BoundedProtocolLine Finish()
        {
            if(!overflow && value.Length>0 && value[^1]=='\r')value.Length--;
            return new BoundedProtocolLine(value.ToString(),overflow);
        }
    }
}

public sealed class BackendClient
{
    private EventWaitHandle? cancel;
    private bool running;
    public string Source {get;}
    public BackendClient(string source) => Source=Path.GetFullPath(source);
    public async Task<FolderDefinition[]> ReadFolderDefinitionsAsync()
    {
        var metadataPath=Path.Combine(AppContext.BaseDirectory,"folder-definitions.json");
        try {
            await using var stream=new FileStream(metadataPath,FileMode.Open,FileAccess.Read,FileShare.Read,4096,FileOptions.Asynchronous|FileOptions.SequentialScan);
            if(stream.Length>64*1024)throw new InvalidDataException("Folder definition resource exceeds its size limit.");
            using var reader=new StreamReader(stream,Encoding.UTF8,true,4096,true);
            var json=await reader.ReadToEndAsync().ConfigureAwait(false);
            var definitions=JsonSerializer.Deserialize<FolderDefinition[]>(json) ?? throw new InvalidDataException("Folder definitions are missing.");
            if(definitions.Length==0 || definitions.Any(item=>string.IsNullOrWhiteSpace(item.Id) || string.IsNullOrWhiteSpace(item.RelativePath)))
                throw new InvalidDataException("Folder definitions are incomplete.");
            if(definitions.Select(item=>item.Id).Distinct(StringComparer.Ordinal).Count()!=definitions.Length)
                throw new InvalidDataException("Folder definitions contain duplicate identifiers.");
            return definitions;
        } catch(Exception error) when(error is IOException or UnauthorizedAccessException or JsonException or InvalidDataException) {
            throw new IOException("Folder destinations could not be loaded. Extract or reinstall the complete package.",error);
        }
    }
    public bool RequestStop() => cancel?.Set() ?? false;
    public async Task<OperationResult> RunAsync(SetupOptions options,string phase,Action<CopyProgress> progress,int copyPageOffset=0,string? copyReviewToken=null)
    {
        if(running) throw new InvalidOperationException("An operation is already running.");
        running=true;
        try {
            var eventName=options.IsCopy ? "Local\\ICloudCopy-"+Guid.NewGuid().ToString("N") : null;
            if(eventName!=null) cancel=new EventWaitHandle(false,EventResetMode.ManualReset,eventName);
            var paths=string.IsNullOrEmpty(options.FolderPathsJson) ? null : JsonSerializer.Deserialize<Dictionary<string,string>>(options.FolderPathsJson);
            var request=new {options.Action,options.Root,options.Backup,options.Music,options.Verified,options.KeepFiles,options.Json,options.DesktopShortcut,FolderPaths=paths,Phase=phase,CancelEventName=eventName,StructuredCopyPage=options.IsCopy,CopyPageOffset=copyPageOffset,CopyReviewToken=copyReviewToken};
            var encoded=Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(request)));
            var bridge=Path.Combine(Source,"tools","Invoke-WinUIBridge.ps1");
            if(!System.IO.File.Exists(bridge)) throw new FileNotFoundException("The application files are incomplete. Extract or reinstall the complete package.",bridge);
            var info=new ProcessStartInfo {
                FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe"),
                WorkingDirectory=Source,UseShellExecute=false,CreateNoWindow=true,
                RedirectStandardOutput=true,RedirectStandardError=true,
                StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8
            };
            foreach(var arg in new[]{"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",bridge,"-EncodedRequest",encoded}) info.ArgumentList.Add(arg);
            using var process=Process.Start(info) ?? throw new IOException("Windows could not start the folder operation.");
            var errors=ReadBoundedTextAsync(process.StandardError,16*1024);
            OperationResult? result=null;
            CopyReviewPage? copyPage=null;
            var invalidCopyPage=false;
            var protocolOverflow=false;
            var other=new StringBuilder();
            var otherTruncated=false;
            var outputReader=new BoundedProtocolReader(process.StandardOutput,512*1024);
            while(await outputReader.ReadLineAsync().ConfigureAwait(false) is {} protocolLine) {
                if(protocolLine.Overflow){protocolOverflow=true;AppendBounded(other,"An oversized protocol line was discarded."+Environment.NewLine,64*1024,ref otherTruncated);continue;}
                var line=protocolLine.Text;
                if(line.StartsWith("@@ICloudProgress:",StringComparison.Ordinal)) {
                    try {var item=JsonSerializer.Deserialize<CopyProgress>(line[17..]);if(item!=null) progress(item);}
                    catch(JsonException) {AppendBounded(other,"Unreadable progress message."+Environment.NewLine,64*1024,ref otherTruncated);}
                } else if(line.StartsWith("@@ICloudCopyPage:",StringComparison.Ordinal)) {
                    try {
                        if(copyPage!=null)throw new InvalidDataException("The copy operation returned more than one review page.");
                        copyPage=JsonSerializer.Deserialize<CopyReviewPage>(line[17..]);
                        if(copyPage is null || copyPage.Version!=1 || copyPage.Type!="copy_review_page" ||
                            string.IsNullOrEmpty(copyPage.ApprovalToken) || copyPage.ApprovalToken.Length!=64 || copyPage.ApprovalToken.Any(character=>!Uri.IsHexDigit(character)) ||
                            copyPage.TotalEntries<0 || copyPage.Offset<0 || copyPage.Offset>copyPage.TotalEntries || copyPage.Offset!=copyPageOffset ||
                            copyPage.Entries is null || copyPage.Entries.Length>100 || (long)copyPage.Offset+copyPage.Entries.Length>copyPage.TotalEntries ||
                            (copyPage.Offset<copyPage.TotalEntries && copyPage.Entries.Length==0) ||
                            (copyPage.NextOffset is int next && ((long)next!=(long)copyPage.Offset+copyPage.Entries.Length || next>=copyPage.TotalEntries)) ||
                            ((long)copyPage.Offset+copyPage.Entries.Length<copyPage.TotalEntries && copyPage.NextOffset is null) ||
                            copyPage.Entries.Any(entry=>entry is null || string.IsNullOrEmpty(entry.Source) || string.IsNullOrEmpty(entry.Destination) || string.IsNullOrEmpty(entry.Action)))
                            throw new InvalidDataException("The copy operation returned an invalid review page.");
                    } catch(JsonException) {invalidCopyPage=true;copyPage=null;AppendBounded(other,"Unreadable copy review page."+Environment.NewLine,64*1024,ref otherTruncated);}
                    catch(InvalidDataException) {invalidCopyPage=true;copyPage=null;AppendBounded(other,"Invalid copy review page."+Environment.NewLine,64*1024,ref otherTruncated);}
                } else if(line.StartsWith("@@ICloudResult:",StringComparison.Ordinal)) {
                    result=JsonSerializer.Deserialize<OperationResult>(line[15..]);
                } else AppendBounded(other,line+Environment.NewLine,64*1024,ref otherTruncated);
            }
            await process.WaitForExitAsync().ConfigureAwait(false);
            var error=await errors.ConfigureAwait(false);
            if(protocolOverflow)return new OperationResult(1,"The operation returned an oversized protocol message. Review the action again.",AppendTransportDetails(other.ToString(),otherTruncated,error));
            if(options.IsCopy && phase!="Apply" && (invalidCopyPage || copyPage is null))
                return new OperationResult(1,"The copy review page could not be loaded. Review technical details before retrying.",other+Environment.NewLine+(result?.Text??"")+error);
            if(result==null) return new OperationResult(process.ExitCode==0 ? 1 : process.ExitCode,"The operation ended without a complete result. Review technical details before retrying.",AppendTransportDetails(other.ToString(),otherTruncated,error));
            if(result.Version!=2 || result.Text is null || result.Text.Length>40*1024 || result.Message is null || result.Message.Length>4096 || result.CapturedCharacters<0)
                return new OperationResult(1,"The operation returned an unsupported or oversized result. Review technical details before retrying.",AppendTransportDetails(other.ToString(),otherTruncated,error));
            if(result.ExitCode!=process.ExitCode) return new OperationResult(1,"The operation returned inconsistent results. Review technical details before retrying.",AppendTransportDetails(result.Text+Environment.NewLine, false,error));
            var message=result.TextTruncated ? result.Message+" Technical details were shortened to keep the result bounded; recovery and backup messages are retained." : result.Message;
            return result with {Message=message,Text=AppendTransportDetails(result.Text, false,error),CopyPage=copyPage};
        } finally {cancel?.Dispose();cancel=null;running=false;}
    }

    private static void AppendBounded(StringBuilder target,string value,int maximumCharacters,ref bool truncated)
    {
        int remaining=maximumCharacters-target.Length;
        if(remaining<=0){truncated=true;return;}
        int count=Math.Min(remaining,value.Length);
        target.Append(value.AsSpan(0,count));
        if(count<value.Length)truncated=true;
    }

    private static string AppendTransportDetails(string text,bool otherTruncated,string stderr)
    {
        var result=new StringBuilder(Math.Min(96*1024,text.Length+stderr.Length+128));
        result.Append(text);
        if(otherTruncated)result.AppendLine("[Unexpected output was bounded.] ");
        if(!string.IsNullOrEmpty(stderr)){
            int remaining=96*1024-result.Length;
            if(remaining>0)result.Append(stderr.AsSpan(0,Math.Min(remaining,stderr.Length)));
            if(stderr.Length>remaining)result.AppendLine("[Standard error was bounded.] ");
        }
        return result.ToString();
    }

    private static async Task<string> ReadBoundedTextAsync(StreamReader reader,int maximumCharacters)
    {
        var result=new StringBuilder(maximumCharacters);
        var buffer=new char[4096];
        int read;
        while((read=await reader.ReadAsync(buffer.AsMemory(0,buffer.Length)).ConfigureAwait(false))>0){
            int count=Math.Min(read,maximumCharacters-result.Length);
            if(count>0)result.Append(buffer,0,count);
        }
        return result.ToString();
    }
}
