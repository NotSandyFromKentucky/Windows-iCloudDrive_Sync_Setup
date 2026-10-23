using Microsoft.UI.Xaml;

namespace ICloudFolderSetup;

public partial class App : Application
{
    private Window? window;
    public App()
    {
        UnhandledException+=(_,error)=>LogStartupError(error.Exception);
        try{InitializeComponent();}catch(Exception error){LogStartupError(error);throw;}
    }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        try{
            window = new MainWindow();
            window.Activate();
#if DEBUG
            var arguments=Environment.GetCommandLineArgs();
            var render=Array.IndexOf(arguments,"--render-fixture");
            if(render>=0 && render+1<arguments.Length)
                await ((MainWindow)window).CaptureFixtureAsync(arguments[render+1]);
#else
            await Task.CompletedTask;
#endif
        }catch(Exception error){LogStartupError(error);Environment.Exit(1);}
    }
    private static void LogStartupError(Exception error)
    {
        try{
            var directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ICloudFolderSettler","Logs");
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory,"native-startup-error.txt"),DateTimeOffset.Now+Environment.NewLine+error);
        }catch{ /* Preserve the original exception if diagnostic storage is unavailable. */ }
    }
}
