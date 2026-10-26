using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
public static class RustUIProbe {
    public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct GuiInfo {
        public uint Size,Flags; public IntPtr Active,Focus,Capture,Menu,Move,Caret; public Rect CaretRect;
    }
    delegate bool EnumCallback(IntPtr window,IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback callback,IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumCallback callback,IntPtr data);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr window);
    public static IntPtr Child(IntPtr parent,int id){IntPtr found=IntPtr.Zero;EnumChildWindows(parent,delegate(IntPtr window,IntPtr data){if(GetDlgCtrlID(window)==id){found=window;return false;}return true;},IntPtr.Zero);return found;}
    public static string Describe(IntPtr parent){var all=new StringBuilder();EnumChildWindows(parent,delegate(IntPtr window,IntPtr data){all.AppendLine(GetDlgCtrlID(window)+" "+window+" "+Text(window)+" style="+Style(window,-16));return true;},IntPtr.Zero);return all.ToString();}
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window,StringBuilder name,int count);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr parent,int id);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] static extern IntPtr SendText(IntPtr window,uint message,IntPtr parameter,StringBuilder text);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] static extern IntPtr SetTextMessage(IntPtr window,uint message,IntPtr parameter,string text);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] public static extern IntPtr Send(IntPtr window,uint message,IntPtr parameter,IntPtr data);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint message,IntPtr parameter,IntPtr data);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window,out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rect rect);
    [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr from,IntPtr to,ref Rect rect,uint points);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window,IntPtr dc,uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr window,uint objectId,ref Guid interfaceId,[MarshalAs(UnmanagedType.Interface)]out Accessibility.IAccessible accessible);
    public static string AccessibleName(IntPtr window){Guid id=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");Accessibility.IAccessible accessible;int result=AccessibleObjectFromWindow(window,unchecked((uint)-4),ref id,out accessible);Marshal.ThrowExceptionForHR(result);try{return accessible.get_accName(0);}finally{Marshal.ReleaseComObject(accessible);}}
    public static int AccessibleRole(IntPtr window){Guid id=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");Accessibility.IAccessible accessible;int result=AccessibleObjectFromWindow(window,unchecked((uint)-4),ref id,out accessible);Marshal.ThrowExceptionForHR(result);try{return Convert.ToInt32(accessible.get_accRole(0));}finally{Marshal.ReleaseComObject(accessible);}}
    static void DescribeAccessible(Accessibility.IAccessible accessible,StringBuilder output,int depth){
        if(depth>12)return;
        try{output.AppendLine(accessible.get_accName(0)+" role="+accessible.get_accRole(0)+" state="+accessible.get_accState(0));
            int count=Math.Min(accessible.accChildCount,200);
            for(int i=1;i<=count;i++){
                object child=null;try{child=accessible.get_accChild(i);}catch{}
                var nested=child as Accessibility.IAccessible;
                if(nested!=null){try{DescribeAccessible(nested,output,depth+1);}finally{Marshal.ReleaseComObject(nested);}}
                else{try{output.AppendLine(accessible.get_accName(i)+" role="+accessible.get_accRole(i)+" state="+accessible.get_accState(i));}catch{}}
            }
        }catch{}
    }
    public static string AccessibleTree(IntPtr window){Guid id=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");Accessibility.IAccessible accessible;int result=AccessibleObjectFromWindow(window,unchecked((uint)-4),ref id,out accessible);Marshal.ThrowExceptionForHR(result);try{var output=new StringBuilder();DescribeAccessible(accessible,output,0);return output.ToString();}finally{Marshal.ReleaseComObject(accessible);}}
    [DllImport("user32.dll",EntryPoint="GetWindowLongW")] public static extern int Style(IntPtr window,int index);
    public static IntPtr Find(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows(delegate(IntPtr window,IntPtr data){uint process;GetWindowThreadProcessId(window,out process);var name=new StringBuilder(128);GetClassName(window,name,name.Capacity);if(process==(uint)pid && name.ToString()=="ICloudRustPreview"){found=window;return false;}return true;},IntPtr.Zero);
        return found;
    }
    public static IntPtr Dialog(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows(delegate(IntPtr window,IntPtr data){uint process;GetWindowThreadProcessId(window,out process);var name=new StringBuilder(128);GetClassName(window,name,name.Capacity);if(process==(uint)pid && name.ToString()=="#32770"){found=window;return false;}return true;},IntPtr.Zero);
        return found;
    }
    public static string Text(IntPtr window) {
        int count=(int)Send(window,0x000E,IntPtr.Zero,IntPtr.Zero);
        var buffer=new StringBuilder(Math.Min(Math.Max(count,0),2200000)+1);
        SendText(window,0x000D,(IntPtr)buffer.Capacity,buffer);return buffer.ToString();
    }
    public static void SetText(IntPtr window,string text){SetTextMessage(window,0x000C,IntPtr.Zero,text);}
    public static void Click(IntPtr window){Send(window,0x00F5,IntPtr.Zero,IntPtr.Zero);}
    public static IntPtr Focus(IntPtr window){uint process;uint thread=GetWindowThreadProcessId(window,out process);var info=new GuiInfo();info.Size=(uint)Marshal.SizeOf(info);if(!GetGUIThreadInfo(thread,ref info))throw new Exception("Cannot inspect focus");return info.Focus;}
    public static void AssertLayout(IntPtr window,int[] ids) {
        Rect client;GetClientRect(window,out client);
        foreach(int id in ids){IntPtr child=GetDlgItem(window,id);if(child==IntPtr.Zero)throw new Exception("Missing control "+id);if(!IsWindowVisible(child))continue;
            Rect rect;GetWindowRect(child,out rect);MapWindowPoints(IntPtr.Zero,window,ref rect,2);
            if(rect.Left<0||rect.Top<0||rect.Right>client.Right||rect.Bottom>client.Bottom||rect.Right<=rect.Left||rect.Bottom<=rect.Top)throw new Exception("Control clipped: "+id);
        }
        Rect status,button;GetWindowRect(GetDlgItem(window,103),out status);GetWindowRect(GetDlgItem(window,1),out button);
        if(status.Bottom>button.Top)throw new Exception("Status overlaps commands");
    }
    public static void Screenshot(IntPtr window,string path){
        Rect rect;GetWindowRect(window,out rect);
        using(var bitmap=new Bitmap(rect.Right-rect.Left,rect.Bottom-rect.Top))using(var graphics=Graphics.FromImage(bitmap)){
            IntPtr dc=graphics.GetHdc();try{if(!PrintWindow(window,dc,2))throw new Exception("PrintWindow failed");}finally{graphics.ReleaseHdc(dc);}
            bitmap.Save(path,ImageFormat.Png);
        }
    }
}
