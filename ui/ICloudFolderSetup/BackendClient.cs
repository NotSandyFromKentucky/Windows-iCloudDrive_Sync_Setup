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
public sealed record OperationResult(int ExitCode,string Message,string Text);
public sealed record CopyProgress(string Stage,string File,int Completed,int Total);
public sealed record FolderDefinition(string Id,string RelativePath);

public sealed class BackendClient
{
    private EventWaitHandle? cancel;
    private bool running;
    public string Source {get;}
    public BackendClient(string source) => Source=Path.GetFullPath(source);
    public FolderDefinition[] ReadFolderDefinitions()
    {
        var result=RunAsync(new SetupOptions("Get folder definitions","","",false,false,false,false),"Preview",_=>{}).GetAwaiter().GetResult();
        if(result.ExitCode!=0)throw new IOException("Folder destinations could not be loaded. Extract or reinstall the complete package. "+result.Text);
        return JsonSerializer.Deserialize<FolderDefinition[]>(result.Text) ?? throw new IOException("Folder definitions are missing.");
    }
    public bool RequestStop() => cancel?.Set() ?? false;
    public async Task<OperationResult> RunAsync(SetupOptions options,string phase,Action<CopyProgress> progress)
    {
        if(running) throw new InvalidOperationException("An operation is already running.");
        running=true;
        try {
            var eventName=options.IsCopy ? "Local\\ICloudCopy-"+Guid.NewGuid().ToString("N") : null;
            if(eventName!=null) cancel=new EventWaitHandle(false,EventResetMode.ManualReset,eventName);
            var paths=string.IsNullOrEmpty(options.FolderPathsJson) ? null : JsonSerializer.Deserialize<Dictionary<string,string>>(options.FolderPathsJson);
            var request=new {options.Action,options.Root,options.Backup,options.Music,options.Verified,options.KeepFiles,options.Json,options.DesktopShortcut,FolderPaths=paths,Phase=phase,CancelEventName=eventName};
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
            var errors=process.StandardError.ReadToEndAsync();
            OperationResult? result=null;
            var other=new StringBuilder();
            while(await process.StandardOutput.ReadLineAsync().ConfigureAwait(false) is {} line) {
                if(line.StartsWith("@@ICloudProgress:",StringComparison.Ordinal)) {
                    try {var item=JsonSerializer.Deserialize<CopyProgress>(line[17..]);if(item!=null) progress(item);}
                    catch(JsonException) {other.AppendLine("Unreadable progress message.");}
                } else if(line.StartsWith("@@ICloudResult:",StringComparison.Ordinal)) {
                    result=JsonSerializer.Deserialize<OperationResult>(line[15..]);
                } else other.AppendLine(line);
            }
            await process.WaitForExitAsync().ConfigureAwait(false);
            var error=await errors.ConfigureAwait(false);
            if(result==null) return new OperationResult(process.ExitCode==0 ? 1 : process.ExitCode,"The operation ended without a complete result. Review technical details before retrying.",other+error);
            if(result.ExitCode!=process.ExitCode) return new OperationResult(1,"The operation returned inconsistent results. Review technical details before retrying.",result.Text+Environment.NewLine+error);
            return result with {Text=result.Text+error};
        } finally {cancel?.Dispose();cancel=null;running=false;}
    }
}
