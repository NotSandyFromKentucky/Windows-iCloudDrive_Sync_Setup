#if DEBUG
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using System.Text.Json;
using Windows.UI.ViewManagement;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;

namespace ICloudFolderSetup;

public sealed partial class MainWindow
{
    // Debug-only rendering fixture; no equivalent switch is present in release builds.
    internal async Task CaptureFixtureAsync(string path)
    {
        for(var i=0;i<30 && Root.ActualWidth==0;i++) await Task.Delay(100);
        if(Argument("--fixture-theme") is {} theme){
            Root.RequestedTheme=theme switch {"Light"=>ElementTheme.Light,"Dark"=>ElementTheme.Dark,_=>throw new ArgumentException("Unknown fixture theme.")};
        }
        if(Argument("--fixture-category") is {} category){
            if(category is not ("Locations" or "Copy" or "Check" or "Cloud")) throw new ArgumentException("Unknown fixture category.");
            ShowCategory(category);
            int index=int.Parse(Argument("--fixture-action-index") ?? "0",System.Globalization.CultureInfo.InvariantCulture);
            if(index<0 || index>=ActionChoice.Items.Count) throw new ArgumentException("Unknown fixture action index.");
            ActionChoice.SelectedIndex=index;
        }
        if(Argument("--fixture-width") is {} width){
            int w=int.Parse(width,System.Globalization.CultureInfo.InvariantCulture);
            int h=int.Parse(Argument("--fixture-height") ?? "720",System.Globalization.CultureInfo.InvariantCulture);
            if(w<400 || w>1600 || h<480 || h>1200) throw new ArgumentException("Fixture size outside supported bounds.");
            double scale=Root.XamlRoot.RasterizationScale;
            AppWindow.Resize(new Windows.Graphics.SizeInt32((int)Math.Round(w*scale),(int)Math.Round(h*scale)));
        }
        await Task.Delay(500);
        Root.UpdateLayout();
        var keyboard=new List<object>();
        var keyboardReverse=new List<string>();
        bool keyboardBoundary=false;
        FrameworkElement? lastFocused=null;
        if(arguments.Contains("--fixture-keyboard",StringComparer.Ordinal)){
            Advanced.IsExpanded=true;
            Root.UpdateLayout();
            if(!ActionChoice.Focus(FocusState.Keyboard)) throw new InvalidOperationException("Action selector could not receive keyboard focus.");
            for(int i=0;i<50;i++){
                if(FocusManager.GetFocusedElement(Root.XamlRoot) is not FrameworkElement focused) throw new InvalidOperationException("Keyboard focus left the native window.");
                lastFocused=focused;
                if(i>0 && ReferenceEquals(focused,ActionChoice)) throw new InvalidOperationException("Unexpected focus cycle before reaching the window boundary.");
                var peer=FrameworkElementAutomationPeer.FromElement(focused) ?? FrameworkElementAutomationPeer.CreatePeerForElement(focused);
                keyboard.Add(new {Id=AutomationProperties.GetAutomationId(focused),Element=focused.Name,
                    Name=peer?.GetName(),Role=peer?.GetAutomationControlType().ToString()});
                if(!FocusManager.TryMoveFocus(FocusNavigationDirection.Next,new FindNextElementOptions{SearchRoot=Root})){keyboardBoundary=true;break;}
                await Task.Delay(30);
            }
            // The host may take focus when the scoped forward search exhausts its tab stops.
            if(lastFocused is Microsoft.UI.Xaml.Controls.Control lastControl) lastControl.Focus(FocusState.Keyboard);
            for(int i=0;i<50;i++){
                if(!FocusManager.TryMoveFocus(FocusNavigationDirection.Previous,new FindNextElementOptions{SearchRoot=Root})) break;
                await Task.Delay(30);
                if(FocusManager.GetFocusedElement(Root.XamlRoot) is not FrameworkElement focused) throw new InvalidOperationException("Reverse focus left the native window.");
                keyboardReverse.Add(focused.Name);
                if(ReferenceEquals(focused,ActionChoice)) break;
            }
            Advanced.IsExpanded=false;
            ActionChoice.Focus(FocusState.Keyboard);
            await Task.Delay(100);
            Root.UpdateLayout();
        }
        var bitmap=new RenderTargetBitmap();
        await bitmap.RenderAsync(Root);
        var pixels=(await bitmap.GetPixelsAsync()).ToArray();
        using var stream=new InMemoryRandomAccessStream();
        var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,(uint)bitmap.PixelWidth,(uint)bitmap.PixelHeight,96,96,pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        using var reader=new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        var bytes=new byte[(int)stream.Size];reader.ReadBytes(bytes);
        await File.WriteAllBytesAsync(path,bytes);
        var settings=new UISettings();
        var highContrast=new AccessibilitySettings().HighContrast;
        var expected=highContrast ? settings.UIElementColor(UIElementType.WindowText)
            : settings.GetColorValue(Root.ActualTheme==ElementTheme.Dark ? UIColorType.AccentLight2 : UIColorType.AccentDark1);
        var windows=((SolidColorBrush)WindowsIdentityTile.Fill).Color;
        var cloud=((SolidColorBrush)CloudIdentityIcon.Foreground).Color;
        object Bounds(FrameworkElement element){
            var point=element.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(0,0));
            return new {X=point.X,Y=point.Y,Width=element.ActualWidth,Height=element.ActualHeight,Visible=element.Visibility==Visibility.Visible};
        }
        await File.WriteAllTextAsync(path+".json.tmp",JsonSerializer.Serialize(new{
            Theme=Root.ActualTheme.ToString(),HighContrast=highContrast,
            SystemAccent=settings.GetColorValue(UIColorType.Accent).ToString(),
            WindowsColor=windows.ToString(),ExpectedWindowsColor=expected.ToString(),CloudColor=cloud.ToString(),
            Keyboard=keyboard,KeyboardBoundary=keyboardBoundary,KeyboardReverse=keyboardReverse,
            Layout=new {Action=Snapshot().Action,Width=Root.ActualWidth,Height=Root.ActualHeight,
                Preview=Bounds(Preview),DryRun=Bounds(DryRun),Apply=Bounds(Apply),CloudRoot=Bounds(CloudRootRow),Backup=Bounds(BackupRow)}
        }));
        File.Move(path+".json.tmp",path+".json",true);
    }
}
#endif
