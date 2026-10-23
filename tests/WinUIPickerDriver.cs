using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;

// A managed entry point is required by .NET Framework's legacy Win32 proxy loader.
// Running the same registration from PowerShell's native host throws in LoadDefaultProxies.
public static class ICloudPickerDriver
{
    static Process process;
    static AutomationElement window,dialog;
    static string dialogTitle;
    static string fixtureRoot;
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool IsWindowVisible(IntPtr handle);
    static void Assert(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
    static void Wait(Func<bool> condition,string message){
        var end=DateTime.UtcNow.AddSeconds(30);
        while(DateTime.UtcNow<end){
            if(process!=null && process.HasExited)throw new InvalidOperationException("Native app exited: "+process.ExitCode);
            if(condition())return;Thread.Sleep(100);
        }
        throw new TimeoutException(message);
    }
    static AutomationElement Id(AutomationElement parent,string id){return parent.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.AutomationIdProperty,id));}
    static AutomationElement Button(string id){return dialog.FindFirst(TreeScope.Descendants,new AndCondition(new PropertyCondition(AutomationElement.AutomationIdProperty,id),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Button)));}
    static AutomationElement Name(string name){return window.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.NameProperty,name));}
    static void Invoke(AutomationElement control){Assert(control!=null,"Missing picker control");((InvokePattern)control.GetCurrentPattern(InvokePattern.Pattern)).Invoke();}
    static string Value(string id){var control=Id(window,id);return control==null ? null : ((ValuePattern)control.GetCurrentPattern(ValuePattern.Pattern)).Current.Value;}
    static IntPtr DialogHandle(){return ICloudTestDesktop.FindWindowForProcess((uint)process.Id,dialogTitle);}
    static void Open(string button,string title){
        dialogTitle=title;Invoke(Id(window,button));
        Wait(()=>DialogHandle()!=IntPtr.Zero && IsWindowVisible(DialogHandle()),"Owned picker missing on hidden desktop: "+title);
        dialog=AutomationElement.FromHandle(DialogHandle());
        Wait(()=>Button("2")!=null && Button("2").Current.IsEnabled,"Picker Cancel unavailable");
    }
    static void Cancel(){
        var cancel=Button("2");
        Console.WriteLine("Cancelling picker: "+dialogTitle+"; control: "+cancel.Current.Name);
        Invoke(cancel);
        // A common dialog can retain its HWND after dismissal. Visibility and the
        // owner's enabled state distinguish dismissal from an open modal window.
        Wait(()=>{var handle=DialogHandle();return (handle==IntPtr.Zero || !IsWindowVisible(handle)) && window.Current.IsEnabled;},"Picker cancel did not dismiss its dialog and re-enable its owner");
        dialog=null;
    }
    static void Choose(string path){
        AutomationElement field=null;
        Wait(()=>{field=Id(dialog,"FileNameControlHost") ?? Id(dialog,"1148") ?? Id(dialog,"1152");return field!=null && field.Current.IsEnabled;},"Picker filename field unavailable");
        // Modern save dialogs expose a combo host and a separate filename edit.
        // Set the editable child rather than the host's independent value.
        var edit=field.Current.ControlType==ControlType.Edit ? field : field.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit));
        var value=(ValuePattern)(edit ?? field).GetCurrentPattern(ValuePattern.Pattern);
        value.SetValue(path);
        Assert(value.Current.Value==path,"Picker filename edit did not retain the requested path");
        var commit=Button("1");
        Console.WriteLine("Choosing picker path: "+path+"; control: "+commit.Current.Name);
        Invoke(commit);
    }
    static void RegisterProviders(){ClientSettings.RegisterClientSideProviderAssembly(new AssemblyName("UIAutomationClientsideProviders, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"));}
    public static int Main(string[] args){
        try{
            RegisterProviders();
            if(args.Length==1 && args[0]=="--probe-providers"){Console.WriteLine("PASS: standalone Win32 provider registration");return 0;}
            Assert(args.Length==2,"Expected repository and fixture paths");
            Assert(ICloudTestDesktop.CurrentName()==Environment.GetEnvironmentVariable("ICLOUD_TEST_DESKTOP") && ICloudTestDesktop.CurrentName()!=ICloudTestDesktop.InputName(),"Picker driver is not on the verified hidden desktop");
            string repo=args[0],fixture=args[1];
            fixtureRoot=fixture;
            var exe=Path.Combine(repo,@"ui\ICloudFolderSetup\bin\x64\Debug\net10.0-windows10.0.19041.0\win-x64\ICloudFolderSetup.exe");
            process=Process.Start(new ProcessStartInfo(exe,"--source \""+repo+"\""){UseShellExecute=false});
            Wait(()=>ICloudTestDesktop.FindWindowForProcess((uint)process.Id,"iCloud folder setup")!=IntPtr.Zero,"Native app did not start");
            window=AutomationElement.FromHandle(ICloudTestDesktop.FindWindowForProcess((uint)process.Id,"iCloud folder setup"));
            Wait(()=>Id(window,"BrowseRoot")!=null,"Folder browse unavailable");
            string original=Value("CloudRoot");
            Open("BrowseRoot","Choose your iCloud Drive folder");Cancel();
            Assert(Value("CloudRoot")==original,"Cancelled folder picker changed its path");
            string chosen=Path.Combine(fixture,"chosen \u00e9");Directory.CreateDirectory(chosen);
            Open("BrowseRoot","Choose your iCloud Drive folder");Choose(chosen);
            Wait(()=>Value("CloudRoot")==chosen,"Folder selection lost its Unicode path");
            Console.WriteLine("PASS: owned folder picker cancellation and Unicode selection");
            ((ExpandCollapsePattern)Id(window,"ActionChoice").GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            Wait(()=>Name("Restore a recovery backup")!=null,"Restore action unavailable");
            ((SelectionItemPattern)Name("Restore a recovery backup").GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            Wait(()=>Id(window,"BrowseBackup")!=null,"Backup browse unavailable");
            original=Value("BackupFile");Open("BrowseBackup","Choose a recovery backup");Cancel();
            Assert(Value("BackupFile")==original,"Cancelled backup picker changed its path");
            string backup=Path.Combine(chosen,"before.json");File.WriteAllText(backup,"{}");
            Open("BrowseBackup","Choose a recovery backup");Choose(backup);
            Wait(()=>Value("BackupFile")==backup,"Backup selection lost its path");
            Assert(!Id(window,"Apply").Current.IsEnabled,"Picking a backup enabled Apply without preview");
            Console.WriteLine("PASS: JSON backup picker cancellation and selection without mutation approval");
            string result=Value("Results");Open("Save","Save folder setup result");Cancel();
            Assert(Directory.GetFiles(fixture,"*.txt",SearchOption.AllDirectories).Length==0,"Cancelled save created a file");
            string saved=Path.Combine(chosen,"result.txt");Open("Save","Save folder setup result");Choose(saved);
            Wait(()=>File.Exists(saved),"Save picker did not create the requested result path");
            string contents=File.ReadAllText(saved);
            Assert(contents==result,"Saved result differs from displayed text; expected length "+result.Length+", actual "+contents.Length);
            Wait(()=>Id(window,"OperationStatus").Current.Name.Contains("Result saved"),"Save completion was not announced");
            Console.WriteLine("PASS: save picker cancellation and exact displayed-result contents");
            return 0;
        }catch(Exception error){
            Console.WriteLine(error);
            try{
                if(window!=null)Console.WriteLine("Native result: "+Value("Results"));
                if(window!=null && Id(window,"OperationStatus")!=null)Console.WriteLine("Native status: "+Id(window,"OperationStatus").Current.Name);
                if(fixtureRoot!=null)foreach(var file in Directory.GetFiles(fixtureRoot,"*",SearchOption.AllDirectories))Console.WriteLine("Fixture file: "+file+"; bytes: "+new FileInfo(file).Length);
                if(dialog!=null){var nodes=dialog.FindAll(TreeScope.Descendants,Condition.TrueCondition);for(int i=0;i<Math.Min(60,nodes.Count);i++)Console.WriteLine(nodes[i].Current.AutomationId+" | "+nodes[i].Current.Name+" | "+nodes[i].Current.ControlType.ProgrammaticName);}
            }catch(Exception diagnostic){Console.WriteLine("Diagnostic snapshot unavailable: "+diagnostic.Message);}
            return 1;
        }finally{if(process!=null){if(!process.HasExited){process.Kill();process.WaitForExit(5000);}process.Dispose();}}
    }
}
