using System.ComponentModel;

// Minimal MVVM base for PowerShell view-models.
//
// This tiny C# type is the realistic way to get INotifyPropertyChanged in PowerShell:
// PowerShell classes cannot declare CLR *events*, so they cannot implement
// INotifyPropertyChanged directly - but they CAN inherit a .NET base that provides the
// PropertyChanged event plus a Raise() helper. In the real app this would live in the
// existing Donut.Launcher C# project (already compiled and loaded), so PS view-models
// could just do `class HostViewModel : ObservableObject { ... }`.
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;

    // Raise change notification for one property. PowerShell classes have no property
    // setters, so the view-model calls this explicitly (or via a Set helper) after
    // mutating a field.
    public void Raise(string propertyName)
    {
        var handler = PropertyChanged;
        if (handler != null)
        {
            handler(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
