using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace DiffKeep.ViewModels;

[JsonSerializable(typeof(SystemInfo))]
internal partial class SystemInfoContext : JsonSerializerContext {}

public class SystemInfo
{
    public string Os { get; set; } = string.Empty;
    public string Runtime { get; set; } = string.Empty;
    public int Processor { get; set; }
    public bool Is64BitProcess { get; set; }
}

public partial class FeedbackViewModel : ObservableObject
{
    private readonly HttpClient _httpClient;
    private const string API_ENDPOINT = "https://127.0.0.1:8080/api/feedback";
    private readonly bool _skipSslVerification = true; // Set to false in production
        
    // You should use a proper API key management solution
    private readonly string _apiKey = "dsk_BLv1bfIM1AQHIh2EoyJ0l1Q9NiHY3Rumo7m6qKQBlPevVre1O3Yd3f7gHIDbZR2Wvdp7GY7FGXJvN4jbW3qe3C";

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

    [ObservableProperty]
    private bool _includeSystemInfo = true;

    [ObservableProperty]
    private string _statusMessage = "";

    [ObservableProperty]
    private IBrush _statusMessageColor;

    public FeedbackViewModel()
    {
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
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
            
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
        return new SystemInfo
        {
            Os = Environment.OSVersion.ToString(),
            Runtime = Environment.Version.ToString(),
            Processor = Environment.ProcessorCount,
            Is64BitProcess = Environment.Is64BitProcess
        };
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