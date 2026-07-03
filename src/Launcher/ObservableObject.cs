using System;
using System.ComponentModel;
using System.Reflection;

namespace Donut.Mvvm
{
    /// <summary>
    /// MVVM base for PowerShell view-models. PowerShell classes cannot declare CLR events,
    /// so they inherit this to get <see cref="INotifyPropertyChanged"/>. View-models call
    /// <see cref="Set"/> (writes a property by name and raises change notification only when
    /// the value actually changes) or <see cref="Raise"/> directly.
    /// </summary>
    /// <remarks>
    /// Compiled into Donut.Launcher so production is pre-compiled; Start-Donut.ps1 also
    /// compiles it from this source (guarded) so the `pwsh -Sta` dev path resolves the type
    /// at parse time.
    /// </remarks>
    public abstract class ObservableObject : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;

        /// <summary>Raise change notification for one property.</summary>
        public void Raise(string propertyName)
        {
            var handler = PropertyChanged;
            if (handler != null)
            {
                handler(this, new PropertyChangedEventArgs(propertyName));
            }
        }

        /// <summary>
        /// Set a public property by name; raises PropertyChanged (and returns true) only when
        /// the value actually changed - so setting the same value in the per-tick pump does
        /// not flood the binding system. Coerces obvious value-type mismatches (e.g. double
        /// percent into an int property) defensively.
        /// </summary>
        public bool Set(string propertyName, object value)
        {
            var prop = GetType().GetProperty(propertyName, BindingFlags.Public | BindingFlags.Instance);
            if (prop == null || !prop.CanWrite)
            {
                return false;
            }

            var current = prop.GetValue(this);
            if (Equals(current, value))
            {
                return false;
            }

            var coerced = value;
            if (value != null && !prop.PropertyType.IsInstanceOfType(value))
            {
                try { coerced = Convert.ChangeType(value, prop.PropertyType); }
                catch { coerced = value; } // let SetValue surface a real incompatibility
            }

            prop.SetValue(this, coerced);
            Raise(propertyName);
            return true;
        }
    }
}
