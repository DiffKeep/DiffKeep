using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Newtonsoft.Json;

namespace DiffKeep.Services;

public class OnnxImageEmbeddingGenerationService : ITextEmbeddingGenerationService
{
    private InferenceSession? _textEncoderSession;
    private readonly string _modelName;
    private readonly ClipTokenizerHelper _tokenizer;
    private int _embeddingDimension = 512; // CLIP typically uses 512 dimensions
    private int _maxTokens = 77; // CLIP standard token length

    public OnnxImageEmbeddingGenerationService()
    {
        _modelName = "clip.onnx";

        // Paths to vocabulary files
        string vocabPath = Path.Join(Program.DataPath, "models", "clip-vocab.json");
        string mergesPath = Path.Join(Program.DataPath, "models", "clip-merges.txt");

        // Make sure the files exist
        if (!File.Exists(vocabPath) || !File.Exists(mergesPath))
        {
            throw new FileNotFoundException(
                "CLIP tokenizer vocabulary files not found. Please download vocab.json and merges.txt.");
        }

        _tokenizer = new ClipTokenizerHelper(vocabPath, mergesPath);
    }

    public async Task LoadModelAsync(string modelPath, bool isEmbeddingModel = true)
    {
        var fullModelPath = Path.Join(Program.DataPath, "models", modelPath);
        if (!File.Exists(fullModelPath))
        {
            throw new FileNotFoundException($"Model file not found at path: {modelPath}");
        }

        // Create session options
        var sessionOptions = new SessionOptions
        {
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL
        };

        // Enable CUDA if available
        if (CheckCudaAvailability())
        {
            sessionOptions.AppendExecutionProvider_CUDA();
        }
        // enable ROCm if available
        else if (CheckRocmAvailability())
        {
            sessionOptions.AppendExecutionProvider_ROCm();
        }

        //sessionOptions.RegisterOrtExtensions();

        // Load the model
        await Task.Run(() =>
        {
            _textEncoderSession = new InferenceSession(fullModelPath, sessionOptions);

            // Print model input and output information for debugging
            Debug.WriteLine("Model Inputs:");
            foreach (var input in _textEncoderSession.InputMetadata)
            {
                Debug.WriteLine($"  - Name: {input.Key}");
                Debug.WriteLine($"    Type: {input.Value.ElementType}");
                Debug.WriteLine($"    Shape: {string.Join(",", input.Value.Dimensions)}");
            }

            Debug.WriteLine("Model Outputs:");
            foreach (var output in _textEncoderSession.OutputMetadata)
            {
                Debug.WriteLine($"  - Name: {output.Key}");
                Debug.WriteLine($"    Type: {output.Value.ElementType}");
                Debug.WriteLine($"    Shape: {string.Join(",", output.Value.Dimensions)}");
            }
        });
    }

    public async Task<IReadOnlyList<float[]>> GenerateEmbeddingAsync(string text, bool isQuery = false)
    {
        if (_textEncoderSession == null)
        {
            await LoadModelAsync(_modelName);
        }

        return await Task.Run(() =>
        {
            Console.WriteLine($"\n===== GENERATING EMBEDDING FOR: '{text}' =====");

            // Tokenize input text
            var tokenizedInput = _tokenizer.Tokenize(text, _maxTokens);

            Console.WriteLine("\nFirst 10 token IDs:");
            for (int i = 0; i < Math.Min(10, tokenizedInput.Length); i++)
            {
                Console.WriteLine($"  [{i}]: {tokenizedInput[i]}");
            }

            // Create input tensor for tokens
            var inputTensor = new DenseTensor<long>(tokenizedInput, new[] { 1, _maxTokens });

            // Create attention mask tensor (1 for tokens, 0 for padding)
            var attentionMask = new long[_maxTokens];
            for (int i = 0; i < _maxTokens; i++)
            {
                // If token id is not 0 (padding token), set attention mask to 1
                attentionMask[i] = tokenizedInput[i] != 0 ? 1 : 0;
            }

            Console.WriteLine("\nAttention mask (first 10 values):");
            for (int i = 0; i < Math.Min(10, attentionMask.Length); i++)
            {
                Console.WriteLine($"  [{i}]: {attentionMask[i]}");
            }

            var attentionMaskTensor = new DenseTensor<long>(attentionMask, new[] { 1, _maxTokens });

            // Create a zero-filled pixel values tensor
            var pixelValues = new float[1 * 3 * 224 * 224]; // All zeros by default
            var pixelValuesTensor = new DenseTensor<float>(pixelValues, new[] { 1, 3, 224, 224 });

            Console.WriteLine("\nUsing zero-filled pixel values");

            // Create input data for the model
            var inputs = new List<NamedOnnxValue>
            {
                NamedOnnxValue.CreateFromTensor("input_ids", inputTensor),
                NamedOnnxValue.CreateFromTensor("attention_mask", attentionMaskTensor),
                NamedOnnxValue.CreateFromTensor("pixel_values", pixelValuesTensor)
            };

            Console.WriteLine("\nRunning model inference...");

            // Run inference
            using var outputs = _textEncoderSession.Run(inputs);

            Console.WriteLine("\nModel outputs:");
            foreach (var output in outputs)
            {
                Console.WriteLine($"  - {output.Name}");
            }

            // Try different outputs to see if any of them contain text-specific embeddings
            var textEmbedsOutput = outputs.FirstOrDefault(o => o.Name == "text_embeds");
            if (textEmbedsOutput == null)
            {
                // If no text_embeds, try other possible outputs
                textEmbedsOutput = outputs.FirstOrDefault(o => o.Name == "last_hidden_state") ??
                                   outputs.FirstOrDefault(o => o.Name == "pooler_output") ??
                                   outputs.FirstOrDefault(); // Just take the first output if nothing else works

                if (textEmbedsOutput == null)
                {
                    throw new InvalidOperationException("Could not find any suitable embeddings in model output");
                }

                Console.WriteLine($"Using '{textEmbedsOutput.Name}' as embedding source");
            }

            var textEmbedsTensor = textEmbedsOutput.AsTensor<float>();

            Console.WriteLine($"\nText embedding shape: {string.Join("x", textEmbedsTensor.Dimensions.ToString())}");

            // Debug the embedding values
            Console.WriteLine("\nFirst 10 embedding values:");
            for (int i = 0; i < Math.Min(10, textEmbedsTensor.Dimensions[1]); i++)
            {
                Console.WriteLine($"  [{i}]: {textEmbedsTensor[0, i]}");
            }

            // Calculate L2 norm to verify normalization
            double sumSquared = 0;
            for (int i = 0; i < textEmbedsTensor.Dimensions[1]; i++)
            {
                sumSquared += textEmbedsTensor[0, i] * textEmbedsTensor[0, i];
            }

            double l2Norm = Math.Sqrt(sumSquared);
            Console.WriteLine($"\nL2 norm of embedding: {l2Norm}");

            // Extract the embedding vector
            var embedding = new float[textEmbedsTensor.Dimensions[1]];
            for (int i = 0; i < embedding.Length; i++)
            {
                embedding[i] = textEmbedsTensor[0, i];
            }

            return new List<float[]> { embedding };
        });
    }


    public string ModelName() => _modelName;

    public bool ModelExists(string? modelFile = null)
    {
        modelFile ??= "clip.onnx";
        var fullModelPath = Path.Join(Program.DataPath, "models", modelFile);
        return File.Exists(fullModelPath);
    }
    
    public int EmbeddingSize() => _maxTokens;

    private bool CheckCudaAvailability()
    {
        try
        {
            return false; // This is a placeholder. In production, you'd check for CUDA availability
        }
        catch
        {
            return false;
        }
    }

    private bool CheckRocmAvailability()
    {
        try
        {
            return false; // This is a placeholder. In production, you'd check for ROCm availability
        }
        catch
        {
            return false;
        }
    }
}

// Helper class for tokenization
internal class ClipTokenizerHelper
{
    private readonly Dictionary<string, int> _vocabDict;
    private readonly List<(string, string)> _merges;
    private const string StartToken = "<|startoftext|>";
    private const string EndToken = "<|endoftext|>";

    // Debug flag
    private readonly bool _debug = true;

    public ClipTokenizerHelper(string vocabPath, string mergesPath)
    {
        // Load vocabulary file
        string vocabJson = File.ReadAllText(vocabPath);
        _vocabDict = JsonConvert.DeserializeObject<Dictionary<string, int>>(vocabJson);

        if (_debug)
        {
            Console.WriteLine($"Loaded vocabulary with {_vocabDict.Count} tokens");
            Console.WriteLine(
                $"Start token ID: {(_vocabDict.TryGetValue(StartToken, out int startId) ? startId.ToString() : "Not found")}");
            Console.WriteLine(
                $"End token ID: {(_vocabDict.TryGetValue(EndToken, out int endId) ? endId.ToString() : "Not found")}");

            // Print a few sample vocabulary items
            Console.WriteLine("Sample vocabulary items:");
            int count = 0;
            foreach (var item in _vocabDict)
            {
                Console.WriteLine($"  {item.Key}: {item.Value}");
                if (++count >= 10) break;
            }
        }

        // Load merges file
        var mergesLines = File.ReadAllLines(mergesPath);
        _merges = new List<(string, string)>();

        // Skip the first line as it's typically a version comment
        for (int i = 1; i < mergesLines.Length; i++)
        {
            var parts = mergesLines[i].Split(' ');
            if (parts.Length == 2)
            {
                _merges.Add((parts[0], parts[1]));
            }
        }

        if (_debug)
        {
            Console.WriteLine($"Loaded {_merges.Count} merge rules");
            // Print a few sample merges
            Console.WriteLine("Sample merge rules:");
            for (int i = 0; i < Math.Min(10, _merges.Count); i++)
            {
                Console.WriteLine($"  {_merges[i].Item1} + {_merges[i].Item2}");
            }
        }
    }

    public long[] Tokenize(string text, int maxTokens)
    {
        if (_debug) Console.WriteLine($"\nTokenizing text: '{text}'");

        // Apply BPE tokenization
        var tokens = new List<int>();

        // Add start token
        if (_vocabDict.TryGetValue(StartToken, out int startTokenId))
        {
            tokens.Add(startTokenId);
            if (_debug) Console.WriteLine($"Added start token: {startTokenId}");
        }

        // CLIP tokenizer uses basic whitespace tokenization followed by BPE
        // Let's lowercase and add spaces around punctuation to better match CLIP's behavior
        text = text.ToLower();
        text = System.Text.RegularExpressions.Regex.Replace(text, @"([.,!?()])", " $1 ");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\s+", " ").Trim();

        if (_debug) Console.WriteLine($"Preprocessed text: '{text}'");

        // Tokenize text using BPE
        foreach (var word in text.Split(' '))
        {
            if (string.IsNullOrWhiteSpace(word)) continue;

            if (_debug) Console.WriteLine($"Tokenizing word: '{word}'");
            var wordTokens = TokenizeBPE(word);

            if (_debug)
            {
                Console.WriteLine($"Word '{word}' tokenized to {wordTokens.Count} tokens:");
                foreach (var t in wordTokens)
                {
                    string tokenStr = _vocabDict.FirstOrDefault(x => x.Value == t).Key ?? "UNKNOWN";
                    Console.WriteLine($"  {t} ({tokenStr})");
                }
            }

            tokens.AddRange(wordTokens);

            // Truncate if exceeding max length (leaving room for end token)
            if (tokens.Count >= maxTokens - 1)
            {
                tokens = tokens.Take(maxTokens - 1).ToList();
                if (_debug) Console.WriteLine("Truncated tokens to fit max length");
                break;
            }
        }

        // Add end token
        if (_vocabDict.TryGetValue(EndToken, out int endTokenId))
        {
            tokens.Add(endTokenId);
            if (_debug) Console.WriteLine($"Added end token: {endTokenId}");
        }

        // Pad to max tokens
        var result = new long[maxTokens];
        for (int i = 0; i < maxTokens; i++)
        {
            result[i] = i < tokens.Count ? tokens[i] : 0; // 0 is padding token
        }

        if (_debug)
        {
            Console.WriteLine($"Final token sequence (length {tokens.Count}, padded to {maxTokens}):");
            for (int i = 0; i < maxTokens; i++)
            {
                if (i < tokens.Count)
                {
                    string tokenStr = _vocabDict.FirstOrDefault(x => x.Value == tokens[i]).Key ?? "UNKNOWN";
                    Console.WriteLine($"  [{i}]: {result[i]} ({tokenStr})");
                }
                else
                {
                    Console.WriteLine($"  [{i}]: {result[i]} (PADDING)");
                }
            }
        }

        return result;
    }

    private List<int> TokenizeBPE(string word)
    {
        if (_debug) Console.WriteLine($"BPE tokenizing: '{word}'");

        // CLIP uses a different BPE tokenization approach than what's implemented here
        // For CLIP, we should:
        // 1. Split word into UTF-8 bytes
        // 2. Create tokens for each byte (prefixed with 'bytes:')
        // 3. Apply BPE merges iteratively

        // This approach may be too simplified for CLIP's actual tokenization
        // Let's try a different approach where we check if the word is in vocabulary directly

        if (_vocabDict.TryGetValue(word, out int wordId))
        {
            if (_debug) Console.WriteLine($"  Found word directly in vocabulary: {wordId}");
            return new List<int> { wordId };
        }

        // CLIP often tokenizes by characters for unknown words
        var result = new List<int>();
        foreach (char c in word)
        {
            string charStr = c.ToString();
            if (_vocabDict.TryGetValue(charStr, out int charId))
            {
                result.Add(charId);
                if (_debug) Console.WriteLine($"  Added character token for '{c}': {charId}");
            }
            else
            {
                if (_debug) Console.WriteLine($"  Character '{c}' not found in vocabulary");
                // Try to find byte representation
                byte[] bytes = Encoding.UTF8.GetBytes(charStr);
                foreach (byte b in bytes)
                {
                    string byteToken = "b" + b.ToString("x");
                    if (_vocabDict.TryGetValue(byteToken, out int byteId))
                    {
                        result.Add(byteId);
                        if (_debug) Console.WriteLine($"  Added byte token for '{c}': {byteId} ({byteToken})");
                    }
                }
            }
        }

        return result;
    }
}