using System;
using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Extensions;
using DiffKeep.Messages;
using DiffKeep.Repositories;
using DiffKeep.Services;

namespace DiffKeep.ViewModels;

public partial class EmbeddingsGenerationViewModel : ViewModelBase
{
    private readonly IEmbeddingGenerationService _embeddingService;
    private readonly IEmbeddingsRepository _embeddingsRepository;
    private readonly ConcurrentQueue<GenerateEmbeddingMessage> _embeddingQueue;
    [ObservableProperty]
    private bool _isProcessing;
    [ObservableProperty]
    private int _totalItems;
    [ObservableProperty]
    private int _processedItems;

    public double Progress => TotalItems == 0 ? 0 : (double)ProcessedItems / TotalItems;

    public ObservableCollection<ProcessingItem> ProcessingItems { get; }

    public EmbeddingsGenerationViewModel(
        IEmbeddingGenerationService embeddingService,
        IEmbeddingsRepository embeddingsRepository)
    {
        _embeddingService = embeddingService;
        _embeddingsRepository = embeddingsRepository;
        _embeddingQueue = new ConcurrentQueue<GenerateEmbeddingMessage>();
        
        ProcessingItems = new ObservableCollection<ProcessingItem>();
        
        Task.Run(async () =>
        {
            // load the fancy new gemma
            await _embeddingService.LoadModelAsync("gemma-3-4b-it-Q6_K.gguf", false);
            Debug.WriteLine("Gemma3 loaded");
            await Task.Delay(1000);
        }).FireAndForget();
        
        
        
        // Subscribe to library updated messages
        WeakReferenceMessenger.Default.Register<GenerateEmbeddingMessage>(this, (r, m) =>
        {
            EnqueueMessageAsync(m).FireAndForget();
        });
    }

    public async Task EnqueueMessageAsync(GenerateEmbeddingMessage message)
    {
        _embeddingQueue.Enqueue(message);
        TotalItems++;
        
        ProcessingItems.Add(new ProcessingItem 
        { 
            ImageId = message.ImageId,
            Status = "Queued",
            Text = message.Text
        });

        if (!IsProcessing)
        {
            await ProcessQueueAsync();
        }
    }

    private async Task ProcessQueueAsync()
    {
        if (IsProcessing) return;
        IsProcessing = true;

        try
        {
            while (_embeddingQueue.TryDequeue(out var message))
            {
                var processingItem = ProcessingItems.First(x => x.ImageId == message.ImageId);
                processingItem.Status = "Processing";

                try
                {
                    var embeddings = await _embeddingService.GenerateEmbeddingAsync(message.Text);
                    foreach (var embedding in embeddings)
                    {
                         await _embeddingsRepository.StoreEmbeddingAsync(
                                                message.ImageId, 
                                                message.EmbeddingType, 
                                                embedding);
                    }
                   

                    processingItem.Status = "Completed";
                }
                catch (Exception ex)
                {
                    processingItem.Status = $"Error: {ex.Message}";
                }

                ProcessedItems++;
                OnPropertyChanged(nameof(Progress));
            }
        }
        finally
        {
            IsProcessing = false;
        }
    }
}

public class ProcessingItem : ViewModelBase
{
    private string _status;

    public long ImageId { get; init; }
    public string Text { get; init; }

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }
}