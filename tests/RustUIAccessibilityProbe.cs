using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using Accessibility;

public static class RustUIAccessibilityProbe
{
    delegate bool EnumCallback(IntPtr window, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr data);

    [DllImport("user32.dll")]
    static extern int GetDlgCtrlID(IntPtr window);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumCallback callback, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, StringBuilder name, int count);

    [DllImport("oleacc.dll")]
    static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);

    static string Escape(string value)
    {
        return (value ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"")
            .Replace("\r", "\\r").Replace("\n", "\\n");
    }

    static IntPtr FindMainWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr window, IntPtr data)
        {
            uint process;
            GetWindowThreadProcessId(window, out process);
            var className = new StringBuilder(128);
            GetClassName(window, className, className.Capacity);
            if (process == (uint)processId && className.ToString() == "ICloudRustPreview")
            {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static IntPtr FindChild(IntPtr parent, int id)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate (IntPtr window, IntPtr data)
        {
            if (GetDlgCtrlID(window) == id)
            {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length != 2) throw new ArgumentException("Expected process ID and control ID.");
            // The standard Win32 client-side providers must be registered from a
            // managed executable entry point, not from the PowerShell host.
            ClientSettings.RegisterClientSideProviderAssembly(new AssemblyName(
                "UIAutomationClientsideProviders, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"));
            int processId = Int32.Parse(args[0]);
            int controlId = Int32.Parse(args[1]);
            IntPtr main = FindMainWindow(processId);
            IntPtr control = main == IntPtr.Zero ? IntPtr.Zero : FindChild(main, controlId);
            if (control == IntPtr.Zero) throw new InvalidOperationException("Requested native control was not found.");

            var element = AutomationElement.FromHandle(control);
            string uiaName = element.Current.Name;
            string uiaType = element.Current.ControlType.ProgrammaticName;
            Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
            IAccessible accessible;
            Marshal.ThrowExceptionForHR(AccessibleObjectFromWindow(control, unchecked((uint)-4), ref iid, out accessible));
            string msaaName;
            string msaaRole;
            try
            {
                msaaName = accessible.get_accName(0);
                msaaRole = Convert.ToString(accessible.get_accRole(0));
            }
            finally
            {
                Marshal.ReleaseComObject(accessible);
            }
            Console.WriteLine("{\"uia_name\":\"" + Escape(uiaName) + "\",\"uia_type\":\"" + Escape(uiaType)
                + "\",\"msaa_name\":\"" + Escape(msaaName) + "\",\"msaa_role\":\"" + Escape(msaaRole) + "\"}");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }
}
