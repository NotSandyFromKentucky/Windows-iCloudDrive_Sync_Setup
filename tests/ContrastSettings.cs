using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ICloudContrastFixture
{
    [StructLayout(LayoutKind.Sequential)]
    private struct HighContrast { public uint Size, Flags; public IntPtr Scheme; }
    public sealed class State { public uint Flags; public string Scheme; }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Parameters(uint action, uint size, ref HighContrast value, uint flags);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    public static State Read()
    {
        var value=new HighContrast { Size=(uint)Marshal.SizeOf(typeof(HighContrast)) };
        if(!Parameters(0x42,value.Size,ref value,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return new State { Flags=value.Flags, Scheme=Marshal.PtrToStringUni(value.Scheme) }; }
        finally { if(value.Scheme!=IntPtr.Zero) LocalFree(value.Scheme); }
    }
    public static void Write(State state)
    {
        var value=new HighContrast { Size=(uint)Marshal.SizeOf(typeof(HighContrast)), Flags=state.Flags,
            Scheme=Marshal.StringToHGlobalUni(state.Scheme ?? "") };
        try {
            if(!Parameters(0x43,value.Size,ref value,2)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(value.Scheme); }
    }
}
