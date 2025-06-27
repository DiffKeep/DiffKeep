using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Avalonia.Threading;
using DiffKeep.Views;
using Serilog;

namespace DiffKeep.Services
{
    public interface IAppStateService
    {
        WindowState GetState();
        void SaveState(WindowState state);
        void UpdateInfoPanelVisibility(bool isVisible);
        bool GetInfoPanelVisibility();
        void SaveImmediately();
    }

    public class AppStateService : IAppStateService
    {
        private WindowState _currentState;
        private readonly string _stateFilePath;
        private DispatcherTimer? _saveDebounceTimer;
        private const int DEBOUNCE_DELAY_MS = 500; // .5 seconds debounce
        private readonly object _stateLock = new object(); // Lock object for thread safety

        public AppStateService()
        {
            _stateFilePath = Path.Combine(Program.DataPath, "windowstate.json");
            
            // Initialize with default or load existing
            if (File.Exists(_stateFilePath))
            {
                try
                {
                    var json = File.ReadAllText(_stateFilePath);
                    _currentState = JsonSerializer.Deserialize(json, JsonContext.Default.WindowState)
                        ?? new WindowState();
                    Log.Debug("Loaded window state");
                }
                catch
                {
                    Log.Error("Failed to read windowstate");
                    _currentState = new WindowState();
                }
            }
            else
            {
                Log.Warning("Windowstate file not found");
                _currentState = new WindowState();
            }

            // Initialize debounce timer
            _saveDebounceTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(DEBOUNCE_DELAY_MS)
            };
            _saveDebounceTimer.Tick += SaveDebounceTimer_Tick;
        }

        public WindowState GetState()
        {
            lock (_stateLock)
            {
                Log.Debug("Getting window state");
                // Return a copy to prevent external modification without going through SaveState
                return (WindowState)_currentState.Clone();
            }
        }

        public void SaveState(WindowState state)
        {
            lock (_stateLock)
            {
                var toSave = (WindowState)state.Clone();
                Log.Debug("Queuing window state save...");
                if (toSave.LeftPanelWidth == 0)
                {
                    toSave.LeftPanelWidth = _currentState.LeftPanelWidth;
                }
                _currentState = toSave;
                
                // Reset the timer (if already running, this will restart it)
                _saveDebounceTimer?.Stop();
                _saveDebounceTimer?.Start();
            }
        }

        private void SaveDebounceTimer_Tick(object? sender, EventArgs e)
        {
            _saveDebounceTimer?.Stop();
            PerformActualSave();
        }

        private void PerformActualSave()
        {
            WindowState stateToSave;
            
            lock (_stateLock)
            {
                stateToSave = (WindowState)_currentState.Clone(); // Create a copy for saving
            }
            
            Log.Debug("Performing actual window state save to disk");
            try
            {
                var directory = Path.GetDirectoryName(_stateFilePath);
                if (directory != null)
                {
                    Directory.CreateDirectory(directory);
                }
                
                var json = JsonSerializer.Serialize(stateToSave, JsonContext.Default.WindowState);
                File.WriteAllText(_stateFilePath, json);
            }
            catch (Exception ex)
            {
                Log.Error("Error saving state: {ExMessage}", ex.Message);
                // Ignore errors during save
            }
        }

        public void UpdateInfoPanelVisibility(bool isVisible)
        {
            lock (_stateLock)
            {
                Log.Debug("Updating info panel visibility to {IsVisible}", isVisible);
                _currentState.ImageViewerInfoPanelOpen = isVisible;
                // We already have the lock, so we can call SaveState
                // which will also acquire the lock, but that's okay with lock statement
                SaveState(_currentState);
            }
        }

        public bool GetInfoPanelVisibility()
        {
            lock (_stateLock)
            {
                Log.Debug("Getting info panel visibility: {CurrentStateImageViewerInfoPanelOpen}", _currentState.ImageViewerInfoPanelOpen);
                return _currentState.ImageViewerInfoPanelOpen;
            }
        }

        // Make sure to save any pending changes when the application shuts down
        public void SaveImmediately()
        {
            _saveDebounceTimer?.Stop();
            PerformActualSave();
        }
    }
}