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
    public static State Read()
    {
        var value=new HighContrast { Size=(uint)Marshal.SizeOf(typeof(HighContrast)) };
        if(!Parameters(0x42,value.Size,ref value,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        // Windows owns this stable pointer. Despite the HIGHCONTRASTW documentation,
        // freeing it corrupts the heap on subsequent queries. Match .NET's interop:
        // https://source.dot.net/System.Private.Windows.Core/Windows/Win32/PInvokeCore.SystemParametersInfo.cs.html
        return new State { Flags=value.Flags, Scheme=Marshal.PtrToStringUni(value.Scheme) };
    }
    public static void Write(State state)
    {
        // SystemParametersInfo may replace the structure's string pointer.
        // Release only the allocation owned by this call, never its returned pointer.
        IntPtr scheme=Marshal.StringToHGlobalUni(state.Scheme ?? "");
        var value=new HighContrast { Size=(uint)Marshal.SizeOf(typeof(HighContrast)), Flags=state.Flags,
            Scheme=scheme };
        try {
            if(!Parameters(0x43,value.Size,ref value,2)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(scheme); }
    }
}
