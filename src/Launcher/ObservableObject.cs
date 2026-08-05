#nullable enable

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
    /// Compiled into Donut.Launcher for production. Start-Donut.ps1 also compiles it from
    /// this source, guarded, so the `pwsh -Sta` dev path resolves the type at parse time.
    /// </remarks>
    public abstract class ObservableObject : INotifyPropertyChanged
    {
        /// <inheritdoc/>
        public event PropertyChangedEventHandler? PropertyChanged;

        /// <summary>Raises change notification for one property.</summary>
        public void Raise(string propertyName)
        {
            var handler = PropertyChanged;
            if (handler != null)
            {
                handler(this, new PropertyChangedEventArgs(propertyName));
            }
        }

        /// <summary>
        /// Set a public property by name, raising PropertyChanged only when the value
        /// actually changed, so the per-tick pump cannot flood the binding system.
        /// Coerces obvious value-type mismatches, such as a double percent into an int.
        /// </summary>
        /// <param name="propertyName">Public instance property to write.</param>
        /// <param name="value">New value, coerced to the property type when it differs.</param>
        /// <returns><c>true</c> when the value changed and notification was raised.</returns>
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
