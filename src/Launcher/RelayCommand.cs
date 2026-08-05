#nullable enable

using System;
using System.Windows.Input;

namespace Donut.Mvvm
{
    /// <summary>
    /// Minimal <see cref="ICommand"/> for MVVM button/gesture binding from PowerShell.
    /// View-models create a RelayCommand from a PowerShell scriptblock (PowerShell converts
    /// a scriptblock to <see cref="Action{Object}"/> automatically). CanExecute is optional
    /// and defaults to always-enabled.
    /// </summary>
    public class RelayCommand : ICommand
    {
        private readonly Action<object?> _execute;
        private readonly Func<object?, bool>? _canExecute;

        /// <summary>Creates an always-enabled command.</summary>
        /// <param name="execute">Action run when the command is invoked.</param>
        public RelayCommand(Action<object?> execute) : this(execute, null) { }

        /// <summary>Creates a command with an optional enabled predicate.</summary>
        /// <param name="execute">Action run when the command is invoked.</param>
        /// <param name="canExecute">Gate for the command, where <c>null</c> is always enabled.</param>
        /// <exception cref="ArgumentNullException"><paramref name="execute"/> is null.</exception>
        public RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute)
        {
            _execute = execute ?? throw new ArgumentNullException(nameof(execute));
            _canExecute = canExecute;
        }

        /// <inheritdoc/>
        // Plain event, not CommandManager, to keep PresentationCore out of the dev path.
        public event EventHandler? CanExecuteChanged;

        /// <summary>Raises <see cref="CanExecuteChanged"/> so bindings re-query the command.</summary>
        public void RaiseCanExecuteChanged()
        {
            var handler = CanExecuteChanged;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        /// <inheritdoc/>
        public bool CanExecute(object? parameter)
        {
            return _canExecute == null || _canExecute(parameter);
        }

        /// <inheritdoc/>
        public void Execute(object? parameter)
        {
            _execute(parameter);
        }
    }
}
