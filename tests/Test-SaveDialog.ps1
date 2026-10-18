#requires -Version 5.1
# A real Windows Save dialog; its parent terminates this dedicated fixture after observation.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExpectedDirectory, [Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
$null=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[ComImport, Guid("c0b4e2f3-ba21-4773-8dba-335ec946eb8b")]
class SaveDialogClass { }

[ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISaveTestShellItem {
    void BindToHandler(IntPtr context, ref Guid handler, ref Guid id, out IntPtr result);
    void GetParent(out ISaveTestShellItem parent);
    void GetDisplayName(uint kind, out IntPtr name);
    void GetAttributes(uint mask, out uint attributes);
    void Compare(ISaveTestShellItem other, uint hint, out int order);
}

[ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISaveTestDialog {
    [PreserveSig] int Show(IntPtr owner);
    void SetFileTypes(uint count, IntPtr types);
    void SetFileTypeIndex(uint index);
    void GetFileTypeIndex(out uint index);
    void Advise(ISaveTestEvents events, out uint cookie);
    void Unadvise(uint cookie);
    void SetOptions(uint options);
    void GetOptions(out uint options);
    void SetDefaultFolder(ISaveTestShellItem folder);
    void SetFolder(ISaveTestShellItem folder);
    void GetFolder(out ISaveTestShellItem folder);
    void GetCurrentSelection(out ISaveTestShellItem item);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
    void GetResult(out ISaveTestShellItem item);
    void AddPlace(ISaveTestShellItem item, uint location);
    void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
    void Close(int result);
    void SetClientGuid(ref Guid id);
    void ClearClientData();
    void SetFilter(IntPtr filter);
}

[ComVisible(true), Guid("973510db-7d7f-452b-8975-74a85828d354"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISaveTestEvents {
    [PreserveSig] int OnFileOk(ISaveTestDialog dialog);
    [PreserveSig] int OnFolderChanging(ISaveTestDialog dialog, ISaveTestShellItem folder);
    [PreserveSig] int OnFolderChange(ISaveTestDialog dialog);
    [PreserveSig] int OnSelectionChange(ISaveTestDialog dialog);
    [PreserveSig] int OnShareViolation(ISaveTestDialog dialog, ISaveTestShellItem item, out uint response);
    [PreserveSig] int OnTypeChange(ISaveTestDialog dialog);
    [PreserveSig] int OnOverwrite(ISaveTestDialog dialog, ISaveTestShellItem item, out uint response);
}

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class SaveTestEvents : ISaveTestEvents {
    public int OnFileOk(ISaveTestDialog d) { return unchecked((int)0x80004004); }
    public int OnFolderChanging(ISaveTestDialog d, ISaveTestShellItem f) { return 0; }
    public int OnFolderChange(ISaveTestDialog d) { return 0; }
    public int OnSelectionChange(ISaveTestDialog d) { return 0; }
    public int OnShareViolation(ISaveTestDialog d, ISaveTestShellItem i, out uint r) { r=0; return 0; }
    public int OnTypeChange(ISaveTestDialog d) { return 0; }
    public int OnOverwrite(ISaveTestDialog d, ISaveTestShellItem i, out uint r) { r=0; return 0; }
}

public static class SaveDialogEvaluation {
    public static string ObserveDefaultFolder(string progressPath, string observedPath) {
        ISaveTestDialog dialog=(ISaveTestDialog)new SaveDialogClass();
        Timer timer=new Timer();
        string folderPath=null;
        Exception failure=null;
        DateTime deadline=DateTime.UtcNow.AddSeconds(20);
        uint cookie=0;
        SaveTestEvents events=new SaveTestEvents();
        try {
            System.IO.File.WriteAllText(progressPath,"COM dialog created");
            // Deliberately do not set a folder or initial directory.
            dialog.SetTitle("Isolated Save dialog path verification");
            dialog.SetFileName("folder-setup-dialog-verification.txt");
            dialog.Advise(events,out cookie);
            timer.Interval=500;
            timer.Tick += delegate {
                ISaveTestShellItem folder=null;
                IntPtr name=IntPtr.Zero;
                try {
                    System.IO.File.AppendAllText(progressPath,"\r\nTimer tick");
                    dialog.GetFolder(out folder);
                    folder.GetDisplayName(0x80058000,out name); // SIGDN_FILESYSPATH
                    folderPath=Marshal.PtrToStringUni(name);
                    System.IO.File.AppendAllText(progressPath,"\r\nFolder: "+folderPath);
                    System.IO.File.WriteAllText(observedPath,folderPath);
                    timer.Stop();
                } catch (Exception ex) {
                    System.IO.File.AppendAllText(progressPath,"\r\nCallback error: "+ex.Message);
                    if (DateTime.UtcNow >= deadline) {
                        failure=ex;
                        timer.Stop();
                        try { dialog.Close(unchecked((int)0x800704c7)); } catch { }
                    }
                } finally {
                    if (name!=IntPtr.Zero) Marshal.FreeCoTaskMem(name);
                    if (folder!=null) Marshal.ReleaseComObject(folder);
                }
            };
            timer.Start();
            System.IO.File.AppendAllText(progressPath,"\r\nOpening dialog");
            int result=dialog.Show(IntPtr.Zero);
            if (failure!=null) throw failure;
            if (String.IsNullOrEmpty(folderPath)) throw new Exception("Save dialog returned no physical folder; HRESULT="+result);
            return folderPath;
        } finally {
            timer.Stop(); timer.Dispose();
            if (cookie!=0) dialog.Unadvise(cookie);
            Marshal.ReleaseComObject(dialog);
            GC.KeepAlive(events);
        }
    }
}
'@
$actual=$null
$failure=$null
try {
    $actual=[SaveDialogEvaluation]::ObserveDefaultFolder($ResultPath+'.progress.txt',$ResultPath+'.observed-path.txt')
    if ($actual -ine $ExpectedDirectory) { throw "Default Save dialog folder mismatch. Expected '$ExpectedDirectory'; resolved '$actual'." }
} catch { $failure=$_.Exception.Message }
[pscustomobject]@{ Success=($null -eq $failure); Expected=$ExpectedDirectory; Actual=$actual; Error=$failure; Mechanism='Real IFileSaveDialog; initial directory left unset; cancelled through its own COM API; no file saved.' } |
    ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($failure) { throw $failure }
