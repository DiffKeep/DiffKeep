using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiffKeep.Settings;
using Serilog;

namespace DiffKeep.ViewModels;

[JsonSerializable(typeof(SystemInfo))]
internal partial class SystemInfoContext : JsonSerializerContext
{
}

public class SystemInfo
{
    public string Os { get; set; } = string.Empty;
    public string Runtime { get; set; } = string.Empty;
    public int Processor { get; set; }
    public bool Is64BitProcess { get; set; }
    public List<string> GpuInfo { get; set; } = new List<string>();
}

public partial class FeedbackViewModel : ObservableObject
{
    private readonly HttpClient _httpClient;
    private const string API_ENDPOINT = "https://diffkeep.com/api/feedback";
    private readonly bool _skipSslVerification = false; // Set to false in production

    private readonly string _apiKey;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSendFeedback))]
    [NotifyCanExecuteChangedFor(nameof(SendFeedbackCommand))]
    private string _feedbackType = "Suggestion";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSendFeedback))]
    [NotifyCanExecuteChangedFor(nameof(SendFeedbackCommand))]
    private string _feedbackMessage = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSendFeedback))]
    [NotifyCanExecuteChangedFor(nameof(SendFeedbackCommand))]
    private string _contactEmail = "";

    [ObservableProperty] private bool _includeSystemInfo = true;

    [ObservableProperty] private string _statusMessage = "";

    [ObservableProperty] private IBrush _statusMessageColor;

    public FeedbackViewModel()
    {
        _apiKey = Secrets.FeedbackApiKey;
        if (_skipSslVerification)
        {
            var handler = new HttpClientHandler
            {
                ServerCertificateCustomValidationCallback = (message, cert, chain, errors) => true
            };
            _httpClient = new HttpClient(handler);
        }
        else
        {
            _httpClient = new HttpClient();
        }

        _httpClient.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));

        StatusMessageColor = Brushes.Black;
    }

    public bool CanSendFeedback =>
        !string.IsNullOrWhiteSpace(FeedbackMessage) && IsValidEmail(ContactEmail);

    [RelayCommand(CanExecute = nameof(CanSendFeedback))]
    private async Task SendFeedbackAsync()
    {
        try
        {
            // Create a POCO for system info if needed
            string? systemInfoJson = null;
            if (IncludeSystemInfo)
            {
                var sysInfo = CreateSystemInfo();
                systemInfoJson = JsonSerializer.Serialize(sysInfo, SystemInfoContext.Default.SystemInfo);
            }

            // Use HttpRequestMessage to build the request manually
            var request = new HttpRequestMessage(HttpMethod.Post, API_ENDPOINT);

            // Add authentication header
            request.Headers.Authorization = new AuthenticationHeaderValue("apikey", _apiKey);

            // Create JSON string manually since we can't use anonymous types with AOT
            var jsonContent = $$"""
                                {
                                  "type": "{{FeedbackType}}",
                                  "message": "{{EscapeJsonString(FeedbackMessage)}}",
                                  "email": "{{EscapeJsonString(ContactEmail)}}",
                                  "includeSystemInfo": {{(IncludeSystemInfo ? "true" : "false")}},
                                  "systemInfo": {{(systemInfoJson != null ? systemInfoJson : "null")}},
                                  "timestamp": "{{DateTime.UtcNow:o}}",
                                  "appVersion": "{{EscapeJsonString(GitVersion.FullVersion)}}"
                                }
                                """;

            request.Content = new StringContent(jsonContent, System.Text.Encoding.UTF8, "application/json");

            var response = await _httpClient.SendAsync(request);

            if (response.IsSuccessStatusCode)
            {
                StatusMessage = "Thank you for your feedback!";
                StatusMessageColor = Brushes.Green;

                // Reset form after successful submission
                FeedbackMessage = "";
                IncludeSystemInfo = true;
                FeedbackType = "Suggestion";
            }
            else
            {
                Log.Debug("Error sending feedback: {Response}", response.Content.ReadAsStringAsync().Result);
                StatusMessage = $"Error sending feedback: {response.ReasonPhrase}";
                StatusMessageColor = Brushes.Red;
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Error: {ex.Message}";
            StatusMessageColor = Brushes.Red;
        }
    }

    private bool IsValidEmail(string email)
    {
        if (string.IsNullOrWhiteSpace(email))
            return true; // Empty email is optional

        // Simple regex for basic email validation
        return Regex.IsMatch(email,
            @"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$");
    }

    private SystemInfo CreateSystemInfo()
    {
        var sysInfo = new SystemInfo
        {
            Os = Environment.OSVersion.ToString(),
            Runtime = Environment.Version.ToString(),
            Processor = Environment.ProcessorCount,
            Is64BitProcess = Environment.Is64BitProcess,
            GpuInfo = GetGpuInfo()
        };

        return sysInfo;
    }

    private List<string> GetGpuInfo()
    {
        var gpuList = new List<string>();

        try
        {
            // Cross-platform GPU detection
            if (OperatingSystem.IsWindows())
            {
                // Windows - use WMI
                using var searcher =
                    new System.Management.ManagementObjectSearcher("SELECT * FROM Win32_VideoController");
                foreach (var obj in searcher.Get())
                {
                    var name = obj["Name"]?.ToString();
                    var memory = obj["AdapterRAM"] != null ? Convert.ToInt64(obj["AdapterRAM"]) / (1024 * 1024) : 0;

                    if (!string.IsNullOrEmpty(name))
                    {
                        gpuList.Add($"{name} ({memory} MB)");
                    }
                }
            }
            else if (OperatingSystem.IsLinux())
            {
                // Linux - read from lspci output
                var process = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "bash",
                        Arguments = "-c \"lspci | grep -E 'VGA|3D|Display'\"",
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };

                process.Start();
                string output = process.StandardOutput.ReadToEnd();
                process.WaitForExit();

                foreach (var line in output.Split('\n'))
                {
                    if (!string.IsNullOrWhiteSpace(line))
                    {
                        gpuList.Add(line.Trim());
                    }
                }
            }
            else if (OperatingSystem.IsMacOS())
            {
                // macOS - use system_profiler
                var process = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "bash",
                        Arguments = "-c \"system_profiler SPDisplaysDataType | grep Chipset\"",
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    }
                };

                process.Start();
                string output = process.StandardOutput.ReadToEnd();
                process.WaitForExit();

                foreach (var line in output.Split('\n'))
                {
                    if (!string.IsNullOrWhiteSpace(line))
                    {
                        gpuList.Add(line.Trim().Replace("Chipset Model:", "").Trim());
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Error getting GPU information");
            gpuList.Add($"Error getting GPU info: {ex.Message}");
        }

        return gpuList;
    }


    private string GetAppVersion()
    {
        return typeof(FeedbackViewModel).Assembly.GetName().Version?.ToString() ?? "Unknown";
    }

    private static string EscapeJsonString(string value)
    {
        if (string.IsNullOrEmpty(value))
            return string.Empty;

        return value
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"")
            .Replace("\n", "\\n")
            .Replace("\r", "\\r")
            .Replace("\t", "\\t");
    }
}