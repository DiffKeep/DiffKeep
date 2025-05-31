using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Messaging;
using DiffKeep.Extensions;
using DiffKeep.Messages;
using DiffKeep.Models;
using DiffKeep.Repositories;
using DiffKeep.Services;

namespace DiffKeep.ViewModels;

public partial class EmbeddingsGenerationViewModel : ViewModelBase
{
    private readonly IEmbeddingGenerationService _embeddingService;
    private readonly IEmbeddingsRepository _embeddingsRepository;
    private readonly ConcurrentQueue<GenerateEmbeddingMessage> _embeddingQueue;
    [ObservableProperty] private bool _isProcessing;
    [ObservableProperty] private int _totalItems;
    [ObservableProperty] private int _processedItems;

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

        // Subscribe to library updated messages
        WeakReferenceMessenger.Default.Register<GenerateEmbeddingMessage>(this,
            (r, m) => { EnqueueMessageAsync(m).FireAndForget(); });
    }

    public async Task EnqueueMessageAsync(GenerateEmbeddingMessage message)
    {
        if (!Program.Settings.UseEmbeddings)
            return;
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
            const int batchSize = 50;
            var batch = new List<(long ImageId, EmbeddingSource Source, string model, float[] Embedding)>(batchSize);

            while (_embeddingQueue.TryDequeue(out var message))
            {
                var processingItem = ProcessingItems.First(x => x.ImageId == message.ImageId);
                processingItem.Status = "Processing";

                try
                {
                    var embeddings = await _embeddingService.GenerateEmbeddingAsync(message.Text);

                    // Add all embeddings for this message to the batch
                    foreach (var embedding in embeddings)
                    {
                        batch.Add((message.ImageId, message.EmbeddingSource, _embeddingService.ModelName(), embedding));
                    }

                    // If we've reached the batch size or this is the last item, process the batch
                    if (batch.Count >= batchSize || _embeddingQueue.IsEmpty)
                    {
                        await _embeddingsRepository.StoreBatchEmbeddingsAsync(batch);
                        batch.Clear();
                    }

                    processingItem.Status = "Completed";
                }
                catch (Exception ex)
                {
                    processingItem.Status = $"Error: {ex.Message}";

                    // If there was an error, try to save any accumulated batch items
                    if (batch.Count > 0)
                    {
                        try
                        {
                            await _embeddingsRepository.StoreBatchEmbeddingsAsync(batch);
                            batch.Clear();
                        }
                        catch
                        {
                            // If batch save fails, log or handle the error as needed
                            Debug.WriteLine("Failed to save batch after error");
                        }
                    }
                }

                ProcessedItems++;
                OnPropertyChanged(nameof(Progress));
            }

            // Process any remaining items in the final batch
            if (batch.Count > 0)
            {
                await _embeddingsRepository.StoreBatchEmbeddingsAsync(batch);
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