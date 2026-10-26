using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using Accessibility;

public static class RustUIAccessibilityProbe
{
    static string currentOperation = "startup";
    delegate bool EnumCallback(IntPtr window, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr data);

    [DllImport("user32.dll")]
    static extern int GetDlgCtrlID(IntPtr window);

    [DllImport("user32.dll")]
    static extern IntPtr GetDlgItem(IntPtr parent, int id);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumCallback callback, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    static extern bool IsChild(IntPtr parent, IntPtr child);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wparam, IntPtr lparam,
        uint flags, uint timeout, out IntPtr result);

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

    static void SendPickerMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam)
    {
        IntPtr result;
        if (SendMessageTimeout(window, message, wparam, lparam, 2, 5000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("The picker filename edit did not process input.");
    }

    static int SelectFolder(string[] args)
    {
        currentOperation = "validate picker handle";
        if (args.Length != 4) throw new ArgumentException("Expected picker handle, owner PID and fixture path.");
        IntPtr dialog = new IntPtr(Int64.Parse(args[1]));
        uint expectedProcess = UInt32.Parse(args[2]);
        uint actualProcess;
        GetWindowThreadProcessId(dialog, out actualProcess);
        if (dialog == IntPtr.Zero || actualProcess != expectedProcess || !IsWindowVisible(dialog))
            throw new InvalidOperationException("The picker is not visible and owned by the requested UI process.");

        currentOperation = "inspect picker automation tree";
        var root = AutomationElement.FromHandle(dialog);
        var field = root.FindFirst(TreeScope.Descendants, new PropertyCondition(
            AutomationElement.AutomationIdProperty, "FileNameControlHost")) ??
            root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "1148")) ??
            root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "1152"));
        currentOperation = "inspect picker filename field";
        if (field == null || !field.Current.IsEnabled)
            throw new InvalidOperationException("The picker filename field is unavailable.");
        var edit = field.Current.ControlType == ControlType.Edit ? field : field.FindFirst(
            TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
        if (edit == null) throw new InvalidOperationException("The picker filename edit is unavailable.");
        var editHandle = new IntPtr(edit.Current.NativeWindowHandle);
        uint editProcess;
        GetWindowThreadProcessId(editHandle, out editProcess);
        if (editHandle == IntPtr.Zero || editProcess != expectedProcess || !IsChild(dialog, editHandle))
            throw new InvalidOperationException("The filename edit is outside the owned picker window.");

        currentOperation = "read picker filename value";
        var value = (ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern);
        currentOperation = "type fixture folder path";
        SendPickerMessage(editHandle, 0x00B1, IntPtr.Zero, new IntPtr(-1)); // EM_SETSEL
        foreach (char character in args[3])
            SendPickerMessage(editHandle, 0x0102, new IntPtr(character), IntPtr.Zero); // WM_CHAR
        if (value.Current.Value != args[3])
            throw new InvalidOperationException("The picker filename edit did not retain the fixture path.");

        currentOperation = "find picker Open button";
        var commit = root.FindFirst(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.AutomationIdProperty, "1"),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)));
        if (commit == null || !commit.Current.IsEnabled)
            throw new InvalidOperationException("The picker Open button is unavailable.");
        currentOperation = "invoke picker Open button";
        var buttonHandle = GetDlgItem(dialog, 1);
        if (buttonHandle == IntPtr.Zero)
            throw new InvalidOperationException("The native Select Folder button handle is unavailable.");
        SendPickerMessage(buttonHandle, 0x00F5, IntPtr.Zero, IntPtr.Zero); // BM_CLICK
        Console.WriteLine("PASS: selected fixture folder through the owned native picker");
        return 0;
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0] == "--select-folder")
            {
                ClientSettings.RegisterClientSideProviderAssembly(new AssemblyName(
                    "UIAutomationClientsideProviders, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"));
                return SelectFolder(args);
            }
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
            Console.Error.WriteLine(error.GetType().Name + " during " + currentOperation + ": " + error.Message);
            return 1;
        }
    }
}
