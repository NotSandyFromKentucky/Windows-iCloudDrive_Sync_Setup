using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ICloudFolderSetup;

public sealed partial class MainWindow
{
    private sealed record DestinationRow(FolderDefinition Definition,TextBlock Label,TextBlock Display,TextBox Editor,Grid EditRow,Grid Container,Grid Content)
    {
        public bool Customized {get;set;}
    }
    private readonly List<DestinationRow> destinationRows=[];
    private bool refreshingRows;
    private void InitializeFolderRows(FolderDefinition[] definitions)
    {
        foreach(var definition in definitions){
            var container=new Grid{ColumnSpacing=12};
            container.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
            container.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
            var symbol=definition.Id switch{
                "Desktop"=>(Symbol)0xE7F4,"Documents"=>Symbol.Document,"Pictures"=>Symbol.Pictures,
                "Videos"=>Symbol.Video,"Downloads"=>Symbol.Download,"Captures"=>Symbol.Camera,"Music"=>Symbol.MusicInfo,_=>Symbol.Folder
            };
            var icon=new FontIcon{Glyph=char.ConvertFromUtf32((int)symbol),VerticalAlignment=VerticalAlignment.Top,Margin=new Thickness(0,4,0,0)};
            AutomationProperties.SetAccessibilityView(icon,Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            container.Children.Add(icon);
            var content=new Grid{ColumnSpacing=12,RowSpacing=4};Grid.SetColumn(content,1);container.Children.Add(content);
            content.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});content.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
            content.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});content.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
            var label=new TextBlock{Text=definition.Id,TextWrapping=TextWrapping.Wrap};content.Children.Add(label);
            var display=new TextBlock{TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
            AutomationProperties.SetName(display,definition.Id+" proposed destination");
            AutomationProperties.SetAutomationId(display,"DefaultDestination_"+definition.Id);content.Children.Add(display);
            var editRow=new Grid{ColumnSpacing=8};
            editRow.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
            editRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});content.Children.Add(editRow);
            var editor=new TextBox{Name="Destination_"+definition.Id,HorizontalAlignment=HorizontalAlignment.Stretch,MinWidth=0};
            AutomationProperties.SetName(editor,definition.Id+" destination");
            AutomationProperties.SetAutomationId(editor,"Destination_"+definition.Id);
            AutomationProperties.SetHelpText(editor,"Choose a destination inside the selected iCloud Drive folder. Existing files are not moved. Preview again after editing.");
            editRow.Children.Add(editor);
            var browse=new Button{Name="BrowseDestination_"+definition.Id,Content="Browse…",VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(browse,1);editRow.Children.Add(browse);
            AutomationProperties.SetName(browse,"Browse for "+definition.Id+" destination");
            AutomationProperties.SetAutomationId(browse,"BrowseDestination_"+definition.Id);
            var row=new DestinationRow(definition,label,display,editor,editRow,container,content);destinationRows.Add(row);
            editor.TextChanged+=(_,_)=>{if(ready && !refreshingRows){row.Customized=true;InvalidateReview();}};
            browse.Click+=async(_,_)=>{
                try{
                    var picker=new FolderPicker(AppWindow.Id){Title="Choose "+definition.Id+" destination",CommitButtonText="Use this folder"};
                    if(await picker.PickSingleFolderAsync() is {} folder)editor.Text=folder.Path;
                }catch(Exception error){ShowError(error);}
            };
            DestinationRows.Children.Add(container);
        }
    }
    private void RefreshFolderRows()
    {
        refreshingRows=true;
        try{
            foreach(var row in destinationRows){
                string path="";
                try{
                    string root=Environment.ExpandEnvironmentVariables(CloudRoot.Text);
                    if(Path.IsPathFullyQualified(root))path=Path.GetFullPath(Path.Combine(root,row.Definition.RelativePath));
                }catch(ArgumentException){ }catch(NotSupportedException){ }
                row.Display.Text=path.Length>0 ? path : "Enter a valid iCloud Drive folder above.";
                if(!row.Customized)row.Editor.Text=path;
                bool included=row.Definition.Id!="Music" || Music.IsChecked==true;
                row.Label.Text=row.Definition.Id+(included ? "" : " (optional)");
                row.Container.Opacity=included ? 1 : 0.6;row.EditRow.IsHitTestVisible=included;
                row.Editor.IsEnabled=included;
                foreach(var button in row.EditRow.Children.OfType<Button>())button.IsEnabled=included;
                row.EditRow.Visibility=CustomizePaths.IsChecked==true ? Visibility.Visible : Visibility.Collapsed;
                row.Display.Visibility=CustomizePaths.IsChecked==true ? Visibility.Collapsed : Visibility.Visible;
            }
            RefreshDestinationLayout();
        }finally{refreshingRows=false;}
    }
    private void RefreshDestinationLayout()
    {
        bool narrow=Root.ActualWidth<640;
        foreach(var row in destinationRows){
            row.Label.Width=narrow ? double.NaN : 110;
            foreach(var element in new FrameworkElement[]{row.Display,row.EditRow}){
                Grid.SetRow(element,narrow ? 1 : 0);Grid.SetColumn(element,narrow ? 0 : 1);Grid.SetColumnSpan(element,narrow ? 2 : 1);
            }
        }
    }
    private string SnapshotFolderPaths()
    {
        if(CustomizePaths.IsChecked!=true || FolderDestinations.Visibility!=Visibility.Visible)return "";
        var paths=new SortedDictionary<string,string>(StringComparer.Ordinal);
        foreach(var row in destinationRows){
            if(row.Definition.Id=="Music" && Music.IsChecked!=true)continue;
            paths.Add(row.Definition.Id,row.Editor.Text);
        }
        return JsonSerializer.Serialize(paths);
    }
}
