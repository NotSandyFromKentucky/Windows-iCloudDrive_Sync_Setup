using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace ICloudFolderSetup;

public sealed partial class MainWindow : Window
{
    private bool ready, busy, stopRequested, confirming;
    private SetupOptions? reviewed;
    private string currentCategory="Locations";
    private string friendly="Your reviewed plan will appear here.", raw="";
    private readonly BackendClient backend;
    private readonly string[] arguments=Environment.GetCommandLineArgs();
    public MainWindow()
    {
        InitializeComponent();
        backend=new BackendClient(FindSource());
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1060,860));
        Root.Loaded+=(_,_)=> {
            var scale=Root.XamlRoot.RasterizationScale;
            var area=Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id,Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
            AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Min(area.Width,(int)Math.Round(960*scale)),Math.Min(area.Height,(int)Math.Round(800*scale))));
        };
        SystemBackdrop=new MicaBackdrop();
        CloudRoot.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"iCloudDrive");
        ready=true;ShowCategory("Locations");
        var mode=Argument("--mode");
        if(mode=="Reset") ActionChoice.SelectedItem="Reset to Windows defaults";
        if(mode=="Check") ShowCategory("Check");
        if(mode=="Install") Root.Loaded+=async(_,_)=>{try{await InstallAsync();}catch(Exception error){ShowError(error);}};
        AppWindow.Closing+=(_,args)=> {
            if(!busy) return;
            args.Cancel=true;
            SetStatus("Operation still running","Wait for its result before closing. Copies can stop after the current file; folder changes must finish.",InfoBarSeverity.Warning);
        };
    }
    private string? Argument(string key)
    {
        var index=Array.IndexOf(arguments,key);
        return index>=0 && index+1<arguments.Length ? arguments[index+1] : null;
    }
    private string FindSource()
    {
        if(Argument("--source") is {} source) return Path.GetFullPath(source);
        foreach(var candidate in new[]{AppContext.BaseDirectory,Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,".."))})
            if(File.Exists(Path.Combine(candidate,"tools","Invoke-WinUIBridge.ps1"))) return candidate;
        return AppContext.BaseDirectory;
    }
    private SetupOptions Snapshot() => new((string?)ActionChoice.SelectedItem ?? "",CloudRoot.Text,BackupFile.Text,
        Music.Visibility==Visibility.Visible && Music.IsChecked==true,
        ManualRoot.Visibility==Visibility.Visible && ManualRoot.IsChecked==true,
        KeepFiles.Visibility==Visibility.Visible && KeepFiles.IsChecked==true,
        JsonOutput.Visibility==Visibility.Visible && JsonOutput.IsChecked==true);
    private void SetStatus(string title,string message,InfoBarSeverity severity=InfoBarSeverity.Informational)
    {
        Status.Title=title;Status.Message=message;Status.Severity=severity;
        AutomationProperties.SetName(Status,title+". "+message);
        if(Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(Status) is {} peer)
            peer.RaiseAutomationEvent(Microsoft.UI.Xaml.Automation.Peers.AutomationEvents.LiveRegionChanged);
    }
    private void RenderResult() => Results.Text=Technical.IsChecked==true ? raw : friendly;
    private void ShowCategory(string category)
    {
        currentCategory=category;
        ready=false;
        var choices=category switch {
            "Copy" => new[]{"Copy files into iCloud folders","Copy files into Windows default folders"},
            "Check" => new[]{"Check iCloud configuration"},
            "Cloud" => new[]{"Create cloud test file","Check cloud return","Clean up cloud test file"},
            _ => new[]{"Set up iCloud folders","Reset to Windows defaults","Restore a recovery backup"}
        };
        PageTitle.Text=category switch {"Copy"=>"Copy files","Check"=>"Check setup","Cloud"=>"Cloud verification",_=>"Folder locations"};
        PageDescription.Text=category switch {
            "Copy"=>"Merge contents without overwriting files. Originals stay in place; folder locations do not change.",
            "Check"=>"Check folder configuration. These checks cannot prove cloud synchronization.",
            "Cloud"=>"Create a small test file, rename it on iCloud.com or another device, then check the returned file. A local-only rename does not verify synchronization.",
            _=>"Choose an action, preview the paths, then confirm the change. Existing files stay in place."
        };
        ActionChoice.ItemsSource=choices;ActionChoice.SelectedIndex=0;
        Navigation.SelectedItem=Navigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item=>(string?)item.Tag==category);
        ready=true;RefreshOptions();InvalidateReview();
    }
    private async void NavigationChanged(NavigationView sender,NavigationViewSelectionChangedEventArgs args)
    {
        if(!ready || busy || args.SelectedItemContainer?.Tag is not string category) return;
        if(category is "Help" or "Recovery" or "Install") {
            try {
                if(category=="Install") {await InstallAsync();return;}
                var path=category=="Help" ? Path.Combine(backend.Source,"README.md") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ICloudFolderSettler","Recovery");
                if(category=="Recovery") Directory.CreateDirectory(path);
                Process.Start(new ProcessStartInfo(path){UseShellExecute=true});
            } catch(Exception error){ShowError(error);}
            finally{
                ready=false;
                Navigation.SelectedItem=Navigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item=>(string?)item.Tag==currentCategory);
                ready=true;
            }
            return;
        }
        ShowCategory(category);
    }
    private void RefreshOptions()
    {
        var action=(string?)ActionChoice.SelectedItem ?? "";
        bool cloud=action is "Set up iCloud folders" or "Copy files into iCloud folders" or "Check iCloud configuration";
        CloudRootRow.Visibility=cloud ? Visibility.Visible : Visibility.Collapsed;
        BackupRow.Visibility=action=="Restore a recovery backup" ? Visibility.Visible : Visibility.Collapsed;
        Music.Visibility=cloud ? Visibility.Visible : Visibility.Collapsed;
        ManualRoot.Visibility=cloud && action!="Check iCloud configuration" ? Visibility.Visible : Visibility.Collapsed;
        KeepFiles.Visibility=action is "Set up iCloud folders" or "Reset to Windows defaults" ? Visibility.Visible : Visibility.Collapsed;
        Advanced.Visibility=ManualRoot.Visibility==Visibility.Visible || KeepFiles.Visibility==Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        JsonOutput.Visibility=action=="Check iCloud configuration" ? Visibility.Visible : Visibility.Collapsed;
        Apply.Content=Snapshot().CommitLabel+"…";
        Apply.Visibility=Snapshot().Mutates ? Visibility.Visible : Visibility.Collapsed;
        DryRun.Visibility=Snapshot().Mutates ? Visibility.Visible : Visibility.Collapsed;
        Preview.Content=Snapshot().Mutates ? "Preview" : "Check";
    }
    private void InvalidateReview()
    {
        reviewed=null;Apply.IsEnabled=false;
        friendly="Options changed. Preview again before applying.";raw="";RenderResult();
        SetStatus("Ready to preview","Review the plan before making changes.");
    }
    private void OptionsChanged(object sender,RoutedEventArgs args) {if(ready && !busy){RefreshOptions();InvalidateReview();}}
    private void TechnicalChanged(object sender,RoutedEventArgs args) {if(ready) RenderResult();}
    private void ShowError(Exception error)
    {
        raw=error.ToString();friendly=error.Message;RenderResult();
        SetStatus("Action needs attention",friendly,InfoBarSeverity.Error);
    }
    private async void BrowseRoot(object sender,RoutedEventArgs args)
    {
        try {
            var picker=new FolderPicker();picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
            if(await picker.PickSingleFolderAsync() is {} folder) CloudRoot.Text=folder.Path;
        }catch(Exception error){ShowError(error);}
    }
    private async void BrowseBackup(object sender,RoutedEventArgs args)
    {
        try {
            var picker=new FileOpenPicker();picker.FileTypeFilter.Add(".json");
            WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
            if(await picker.PickSingleFileAsync() is {} file) BackupFile.Text=file.Path;
        }catch(Exception error){ShowError(error);}
    }
    private async void SaveResult(object sender,RoutedEventArgs args)
    {
        try {
            var picker=new FileSavePicker{SuggestedFileName="folder-setup-result"};picker.FileTypeChoices.Add("Text",new[]{".txt"});
            WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
            if(await picker.PickSaveFileAsync() is {} file) await File.WriteAllTextAsync(file.Path,Results.Text);
        }catch(Exception error){ShowError(error);}
    }
    private void SetBusy(bool value,SetupOptions options)
    {
        busy=value;
        foreach(var item in Navigation.MenuItems.Concat(Navigation.FooterMenuItems).OfType<Control>()) item.IsEnabled=!value;
        SetInteraction(Options,!value);
        Preview.IsEnabled=!value;DryRun.IsEnabled=!value;Apply.IsEnabled=false;Save.IsEnabled=!value;
        Stop.Visibility=value && options.IsCopy ? Visibility.Visible : Visibility.Collapsed;Stop.IsEnabled=value;
        Progress.Visibility=value ? Visibility.Visible : Visibility.Collapsed;
        if(value){Progress.IsIndeterminate=true;Progress.Value=0;CurrentFile.Text="";CurrentFile.Visibility=Visibility.Collapsed;}
    }
    private static void SetInteraction(UIElement element,bool enabled)
    {
        if(element is Control control) control.IsEnabled=enabled;
        else if(element is Panel panel) foreach(var child in panel.Children) SetInteraction(child,enabled);
    }
    private async Task RunAsync(string phase)
    {
        if(busy || confirming) return;
        var options=Snapshot();
        if(phase=="Apply") {
            if(reviewed!=options){SetStatus("Preview required","Options changed. Preview this plan again.",InfoBarSeverity.Warning);return;}
            string consequence=options.IsCopy ? "Copy the reviewed files without overwriting existing content. Originals remain in place. Cloud files may download and destination copies may synchronize. Folder locations will not change."
                : options.Action=="Clean up cloud test file" ? "Remove the exact verification files shown in the plan. This deletion will synchronize to iCloud and other devices."
                : options.Action=="Create cloud test file" ? "Create the small verification file in your iCloud Documents folder."
                : "Apply the reviewed folder locations. Existing files stay where they are. A fresh recovery backup will be created before any folder-setting change.";
            var dialog=new ContentDialog {XamlRoot=Root.XamlRoot,Title=options.CommitLabel,Content=consequence,PrimaryButtonText=options.CommitLabel,CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};
            confirming=true;
            ContentDialogResult answer;
            try{answer=await dialog.ShowAsync();}finally{confirming=false;}
            if(answer!=ContentDialogResult.Primary) return;
            if(busy || Snapshot()!=options || reviewed!=options) return;
        }
        reviewed=null;stopRequested=false;SetBusy(true,options);
        Status.StartBringIntoView(new BringIntoViewOptions{AnimationDesired=false});
        SetStatus("Working",options.IsCopy ? "Copying can stop after the current file has been verified." : "Wait for the operation to finish. Folder changes cannot be interrupted.");
        try {
            var result=await backend.RunAsync(options,phase,item=>DispatcherQueue.TryEnqueue(()=> {
                if(!busy) return;
                CurrentFile.Visibility=Visibility.Visible;CurrentFile.Text=item.File;
                if(item.Total>0){Progress.IsIndeterminate=false;Progress.Maximum=item.Total;Progress.Value=Math.Clamp(item.Completed,0,item.Total);}
                if(!stopRequested) SetStatus(item.Stage,item.Total>0 ? $"{item.Completed} of {item.Total} files verified" : "Reading the copy plan. Large files and cloud downloads may take time.");
            }));
            raw=result.Text+Environment.NewLine+"Exit code: "+result.ExitCode;
            friendly=result.Message+Environment.NewLine+result.Text;RenderResult();
            SetStatus(result.ExitCode==0 ? phase=="Apply" ? "Action completed" : "Review the result" : result.ExitCode==3 ? "Copy stopped safely" : "Action needs attention",result.Message,result.ExitCode==0 ? InfoBarSeverity.Success : result.ExitCode is 2 or 3 ? InfoBarSeverity.Warning : InfoBarSeverity.Error);
            if(result.ExitCode==0 && phase!="Apply" && options.Mutates) reviewed=options;
        }catch(Exception error){ShowError(error);}
        finally{SetBusy(false,options);Apply.IsEnabled=reviewed==Snapshot();Preview.Focus(FocusState.Programmatic);}
    }
    private async Task RunSafelyAsync(string phase){try{await RunAsync(phase);}catch(Exception error){ShowError(error);}}
    private async void PreviewClick(object sender,RoutedEventArgs args) => await RunSafelyAsync("Preview");
    private async void DryRunClick(object sender,RoutedEventArgs args) => await RunSafelyAsync("DryRun");
    private async void ApplyClick(object sender,RoutedEventArgs args) => await RunSafelyAsync("Apply");
    private void StopClick(object sender,RoutedEventArgs args)
    {
        if(backend.RequestStop()){stopRequested=true;Stop.IsEnabled=false;SetStatus("Stop requested","Finishing the current file and verification. Large files or cloud downloads can delay stopping.",InfoBarSeverity.Warning);}
    }
    private async Task InstallAsync()
    {
        if(busy || confirming) return;
        var desktop=new CheckBox{Content="Also add a desktop shortcut"};
        var panel=new StackPanel{Spacing=16};
        panel.Children.Add(new TextBlock{Text="Copy verified application files for your Windows account and add a Start menu shortcut. No administrator access is needed. Folder locations and existing files will not change.",TextWrapping=TextWrapping.Wrap});
        panel.Children.Add(desktop);
        var dialog=new ContentDialog{XamlRoot=Root.XamlRoot,Title="Install for your account",Content=panel,PrimaryButtonText="Install for me",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};
        confirming=true;
        ContentDialogResult answer;
        try{answer=await dialog.ShowAsync();}finally{confirming=false;}
        if(answer!=ContentDialogResult.Primary) return;
        var options=new SetupOptions("Install for me","","",false,false,false,false,desktop.IsChecked==true);
        reviewed=null;SetBusy(true,options);
        SetStatus("Installing","Verifying and copying the application files.");
        try{
            var result=await backend.RunAsync(options,"Apply",_=>{});
            raw=result.Text+Environment.NewLine+"Exit code: "+result.ExitCode;
            friendly=result.Message+Environment.NewLine+result.Text;RenderResult();
            SetStatus(result.ExitCode==0 ? "Installation completed" : "Installation needs attention",result.Message,result.ExitCode==0 ? InfoBarSeverity.Success : InfoBarSeverity.Error);
            Status.StartBringIntoView(new BringIntoViewOptions{AnimationDesired=false});
        }catch(Exception error){ShowError(error);}
        finally{SetBusy(false,options);Preview.Focus(FocusState.Programmatic);}
    }
}
