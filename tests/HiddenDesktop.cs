using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

// Test infrastructure only. Never switches the input desktop.
public static class ICloudTestDesktop
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x,y,width,height,charsX,charsY,fill,flags;
        public short show,reservedSize; public IntPtr reservedData,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
    [StructLayout(LayoutKind.Sequential)]
    struct Limits {
        public long processTime,jobTime; public uint flags;
        public UIntPtr minimum,maximum; public uint active;
        public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public Limits basic; public IoCounters io;
        public UIntPtr processMemory,jobMemory,peakProcess,peakJob;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    delegate bool EnumWindowCallback(IntPtr window,IntPtr value);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback,IntPtr value);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window,StringBuilder text,int count);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessage(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder value,int size,out int needed);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref Startup startup,out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,int size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static string CurrentName() {
        var name=new StringBuilder(256); int needed;
        Check(GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()),2,name,512,out needed));
        return name.ToString();
    }
    public static string InputName() {
        IntPtr desktop=OpenInputDesktop(0,false,1); Check(desktop!=IntPtr.Zero);
        try { var name=new StringBuilder(256); int needed;
            Check(GetUserObjectInformation(desktop,2,name,512,out needed)); return name.ToString();
        } finally { CloseDesktop(desktop); }
    }
    public static IntPtr FindWindowForProcess(uint processId,string title) {
        IntPtr result=IntPtr.Zero;
        EnumWindows((window,value)=> {
            uint owner;GetWindowThreadProcessId(window,out owner);
            if(owner!=processId) return true;
            var text=new StringBuilder(512);GetWindowText(window,text,text.Capacity);
            if(text.ToString()!=title) return true;
            result=window;return false;
        },IntPtr.Zero);
        return result;
    }
    public static void CloseWindow(IntPtr window) { Check(PostMessage(window,0x0010,IntPtr.Zero,IntPtr.Zero)); }
    public static int Run(string executable,string arguments,string directory,string desktopName,int timeoutSeconds) {
        if(!desktopName.StartsWith("ICloudTests-",StringComparison.Ordinal) || desktopName.IndexOf('\\')>=0)
            throw new ArgumentException("Invalid test desktop name.");
        // Create/read/write windows; intentionally omit DESKTOP_SWITCHDESKTOP.
        IntPtr desktop=CreateDesktop(desktopName,IntPtr.Zero,IntPtr.Zero,0,0xC3,IntPtr.Zero);
        Check(desktop!=IntPtr.Zero);
        IntPtr job=IntPtr.Zero; var process=new ProcessInfo();
        try {
            job=CreateJobObject(IntPtr.Zero,null); Check(job!=IntPtr.Zero);
            var limits=new ExtendedLimits(); limits.basic.flags=0x2000; // KILL_ON_JOB_CLOSE
            Check(SetInformationJobObject(job,9,ref limits,Marshal.SizeOf(limits)));
            var startup=new Startup(); startup.cb=Marshal.SizeOf(startup); startup.desktop=desktopName;
            Check(CreateProcess(executable,new StringBuilder("\""+executable+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0x08000004,IntPtr.Zero,directory,ref startup,out process));
            Check(AssignProcessToJobObject(job,process.process));
            Check(ResumeThread(process.thread)!=0xFFFFFFFF);
            uint wait=WaitForSingleObject(process.process,checked((uint)timeoutSeconds*1000));
            if(wait==258) throw new TimeoutException("Hidden-desktop test exceeded its timeout; its process tree will be stopped.");
            Check(wait==0); uint code; Check(GetExitCodeProcess(process.process,out code));
            return unchecked((int)code);
        } finally {
            // Covers assignment failure while the child is still suspended as well.
            if(process.process!=IntPtr.Zero) { if(WaitForSingleObject(process.process,0)==258) TerminateProcess(process.process,124); }
            if(job!=IntPtr.Zero) CloseHandle(job);
            if(process.thread!=IntPtr.Zero) CloseHandle(process.thread);
            if(process.process!=IntPtr.Zero) CloseHandle(process.process);
            CloseDesktop(desktop);
        }
    }
}
