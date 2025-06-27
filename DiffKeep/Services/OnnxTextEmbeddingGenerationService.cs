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
using Newtonsoft.Json.Linq;
using Serilog;

namespace DiffKeep.Services;

public class OnnxTextEmbeddingGenerationService : ITextEmbeddingGenerationService
{
    private InferenceSession? _textEncoderSession;
    private readonly string _modelName;
    private readonly MpnetTokenizerHelper _tokenizer;
    private readonly int _embeddingDimension = 768;
    private readonly int _maxTokens = 512;

    public OnnxTextEmbeddingGenerationService()
    {
        _modelName = "all-mpnet-base-v2.onnx";

        // Paths to tokenizer file
        string tokenizerPath = Path.Join(Program.DataPath, "models", "all-mpnet-base-v2-tokenizer.json");

        // Make sure the files exist
        if (!File.Exists(tokenizerPath))
        {
            throw new FileNotFoundException(
                "CLIP tokenizer file not found. Please download tokenizer.json.");
        }

        _tokenizer = new MpnetTokenizerHelper(tokenizerPath);
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
            //sessionOptions.AppendExecutionProvider_CUDA();
        }
        // enable ROCm if available
        else if (CheckRocmAvailability())
        {
            //sessionOptions.AppendExecutionProvider_ROCm();
        }

        // Load the model
        await Task.Run(() =>
        {
            _textEncoderSession = new InferenceSession(fullModelPath, sessionOptions);

            // Print model input and output information for debugging
            Log.Verbose("Model Inputs:");
            foreach (var input in _textEncoderSession.InputMetadata)
            {
                Log.Verbose("  - Name: {InputKey}", input.Key);
                Log.Verbose("    Type: {ValueElementType}", input.Value.ElementType);
                Log.Verbose("    Shape: {Join}", string.Join(",", input.Value.Dimensions));
            }

            Log.Verbose("Model Outputs:");
            foreach (var output in _textEncoderSession.OutputMetadata)
            {
                Log.Verbose("  - Name: {OutputKey}", output.Key);
                Log.Verbose("    Type: {ValueElementType}", output.Value.ElementType);
                Log.Verbose("    Shape: {Join}", string.Join(",", output.Value.Dimensions));
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
            // Tokenize input text
            var tokenizedResult = _tokenizer.Tokenize(text, _maxTokens);
            var inputIds = tokenizedResult.InputIds;
            var attentionMask = tokenizedResult.AttentionMask;
            var tokenTypeIds = tokenizedResult.TokenTypeIds;

            // Create input tensors
            var inputIdsTensor = new DenseTensor<long>(inputIds, new[] { 1, inputIds.Length });
            var attentionMaskTensor = new DenseTensor<long>(attentionMask, new[] { 1, attentionMask.Length });
            var tokenTypeIdsTensor = new DenseTensor<long>(tokenTypeIds, new[] { 1, tokenTypeIds.Length });

            // Create input data for the model
            var inputs = new List<NamedOnnxValue>();
            
            // Add the required inputs for the model
            foreach (var input in _textEncoderSession.InputMetadata.Keys)
            {
                if (input == "input_ids")
                {
                    inputs.Add(NamedOnnxValue.CreateFromTensor("input_ids", inputIdsTensor));
                }
                else if (input == "attention_mask")
                {
                    inputs.Add(NamedOnnxValue.CreateFromTensor("attention_mask", attentionMaskTensor));
                }
                else if (input == "token_type_ids")
                {
                    inputs.Add(NamedOnnxValue.CreateFromTensor("token_type_ids", tokenTypeIdsTensor));
                }
                else
                {
                    Console.WriteLine($"Warning: Unhandled input: {input}");
                }
            }

            // Run inference
            using var outputs = _textEncoderSession.Run(inputs);

            // Try different outputs to find sentence embedding
            var embeddingOutput = outputs.FirstOrDefault(o => o.Name == "sentence_embedding") ??
                                 outputs.FirstOrDefault(o => o.Name == "last_hidden_state") ??
                                 outputs.FirstOrDefault(o => o.Name == "pooler_output") ??
                                 outputs.FirstOrDefault(); // Just take the first output if nothing else works

            if (embeddingOutput == null)
            {
                throw new InvalidOperationException("Could not find any suitable embeddings in model output");
            }

            var embeddingTensor = embeddingOutput.AsTensor<float>();

            // Extract the embedding vector - handle different output formats
            float[] embedding;
            
            if (embeddingTensor.Dimensions.Length == 2 && embeddingTensor.Dimensions[0] == 1)
            {
                // For pooler_output or sentence_embedding: [1, embedding_dim]
                embedding = new float[embeddingTensor.Dimensions[1]];
                for (int i = 0; i < embedding.Length; i++)
                {
                    embedding[i] = embeddingTensor[0, i];
                }
            }
            else if (embeddingTensor.Dimensions.Length == 3 && embeddingTensor.Dimensions[0] == 1)
            {
                // For last_hidden_state: [1, sequence_length, embedding_dim]
                // Use CLS token (first token) as the sentence embedding
                embedding = new float[embeddingTensor.Dimensions[2]];
                for (int i = 0; i < embedding.Length; i++)
                {
                    embedding[i] = embeddingTensor[0, 0, i];
                }
            }
            else
            {
                throw new InvalidOperationException($"Unexpected embedding tensor shape: {string.Join("x", embeddingTensor.Dimensions.ToString())}");
            }

            // Calculate L2 norm to verify normalization
            double sumSquared = 0;
            for (int i = 0; i < embedding.Length; i++)
            {
                sumSquared += embedding[i] * embedding[i];
            }

            double l2Norm = Math.Sqrt(sumSquared);

            // Normalize if needed (some models don't output normalized embeddings)
            if (Math.Abs(l2Norm - 1.0) > 1e-5)
            {
                for (int i = 0; i < embedding.Length; i++)
                {
                    embedding[i] /= (float)l2Norm;
                }
            }

            return new List<float[]> { embedding };
        });
    }

    public string ModelName() => _modelName;

    public bool ModelExists(string? modelFile = null)
    {
        modelFile ??= _modelName;
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
internal class MpnetTokenizerHelper
{
    private readonly Dictionary<string, int> _vocab;
    private readonly string _unkToken;
    private readonly string _clsToken;
    private readonly string _sepToken;
    private readonly string _padToken;
    private readonly int _unkTokenId;
    private readonly int _clsTokenId;
    private readonly int _sepTokenId;
    private readonly int _padTokenId;
    private readonly bool _doLowerCase;
    private readonly string _continuingSubwordPrefix;
    private readonly int _maxInputCharsPerWord;
    
    // Debug flag
    private readonly bool _debug = false;

    public MpnetTokenizerHelper(string tokenizerPath)
    {
        try
        {
            // Load tokenizer configuration
            string tokenizerJson = File.ReadAllText(tokenizerPath);
            var tokenizerConfig = JObject.Parse(tokenizerJson);
            
            // Get the model configuration
            var modelConfig = tokenizerConfig["model"];
            if (modelConfig == null)
            {
                throw new InvalidOperationException("Could not find model configuration in tokenizer file");
            }
            
            // Get the vocabulary from the model
            var vocabToken = modelConfig["vocab"];
            if (vocabToken == null)
            {
                throw new InvalidOperationException("Could not find vocabulary in tokenizer file");
            }
            
            // Parse the vocabulary
            _vocab = vocabToken.ToObject<Dictionary<string, int>>();
            if (_vocab == null)
            {
                throw new InvalidOperationException("Failed to parse vocabulary");
            }
            
            if (_debug)
            {
                Log.Verbose("Loaded vocabulary with {VocabCount} tokens", _vocab.Count);
                
                // Print a few sample vocabulary items
                Log.Verbose("Sample vocabulary items:");
                int count = 0;
                foreach (var item in _vocab)
                {
                    Log.Verbose("  {ItemKey}: {ItemValue}", item.Key, item.Value);
                    if (++count >= 10) break;
                }
            }
            
            // Get tokenizer settings
            _unkToken = modelConfig["unk_token"]?.ToString() ?? "[UNK]";
            _continuingSubwordPrefix = modelConfig["continuing_subword_prefix"]?.ToString() ?? "##";
            _maxInputCharsPerWord = modelConfig["max_input_chars_per_word"]?.ToObject<int>() ?? 100;
            
            // Get special tokens and their IDs
            var addedTokens = tokenizerConfig["added_tokens"];
            if (addedTokens != null && addedTokens.Type == JTokenType.Array)
            {
                foreach (var token in addedTokens)
                {
                    string content = token["content"]?.ToString() ?? "";
                    
                    if (content == "<s>")
                    {
                        _clsToken = content;
                        _clsTokenId = token["id"].ToObject<int>();
                    }
                    else if (content == "</s>")
                    {
                        _sepToken = content;
                        _sepTokenId = token["id"].ToObject<int>();
                    }
                    else if (content == "<pad>")
                    {
                        _padToken = content;
                        _padTokenId = token["id"].ToObject<int>();
                    }
                    else if (content == "<unk>" || content == "[UNK]")
                    {
                        _unkToken = content;
                        _unkTokenId = token["id"].ToObject<int>();
                    }
                }
            }
            
            // Set defaults if not found
            _clsToken ??= "<s>";
            _sepToken ??= "</s>";
            _padToken ??= "<pad>";
            
            if (!_vocab.TryGetValue(_clsToken, out _clsTokenId))
            {
                _clsTokenId = 0; // Default <s> ID
            }
            
            if (!_vocab.TryGetValue(_sepToken, out _sepTokenId))
            {
                _sepTokenId = 2; // Default </s> ID
            }
            
            if (!_vocab.TryGetValue(_padToken, out _padTokenId))
            {
                _padTokenId = 1; // Default <pad> ID
            }
            
            if (!_vocab.TryGetValue(_unkToken, out _unkTokenId))
            {
                _unkTokenId = 3; // Default <unk> ID
            }
            
            // Check normalizer settings
            var normalizer = tokenizerConfig["normalizer"];
            _doLowerCase = normalizer?["lowercase"]?.ToObject<bool>() ?? true;
            
            if (_debug)
            {
                Log.Verbose("CLS token: {ClsToken} (ID: {ClsTokenId})", _clsToken, _clsTokenId);
                Log.Verbose("SEP token: {SepToken} (ID: {SepTokenId})", _sepToken, _sepTokenId);
                Log.Verbose("PAD token: {PadToken} (ID: {PadTokenId})", _padToken, _padTokenId);
                Log.Verbose("UNK token: {UnkToken} (ID: {UnkTokenId})", _unkToken, _unkTokenId);
                Log.Verbose("Lowercase: {DoLowerCase}", _doLowerCase);
                Log.Verbose("Continuing subword prefix: {ContinuingSubwordPrefix}", _continuingSubwordPrefix);
            }
        }
        catch (Exception ex)
        {
            Log.Verbose("Error initializing tokenizer: {Exception}", ex);
            throw new InvalidOperationException("Failed to parse tokenizer config or vocabulary", ex);
        }
    }

    public (long[] InputIds, long[] AttentionMask, long[] TokenTypeIds) Tokenize(string text, int maxTokens)
    {
        if (_debug) Log.Verbose("Tokenizing text: '{Text}'", text);

        // Apply pre-processing
        if (_doLowerCase)
        {
            text = text.ToLower();
        }
        
        // Create result arrays
        var inputIds = new long[maxTokens];
        var attentionMask = new long[maxTokens];
        var tokenTypeIds = new long[maxTokens]; // All zeros for single sequence
        
        // Start with CLS token
        inputIds[0] = _clsTokenId;
        attentionMask[0] = 1; // Attend to this token
        
        if (_debug) Log.Verbose("Added CLS token: {ClsToken} (ID: {ClsTokenId})", _clsToken, _clsTokenId);
        
        // Tokenize and add tokens
        var tokens = new List<long>();
        tokens.Add(_clsTokenId);
        
        // Split text into words using basic whitespace tokenization
        string[] words = text.Split(new[] { ' ', '\t', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries);
        
        int tokenPosition = 1; // Start after CLS token
        
        foreach (var word in words)
        {
            if (string.IsNullOrEmpty(word)) continue;
            
            // Apply WordPiece tokenization to the word
            var wordTokens = TokenizeWord(word);
            
            if (_debug)
            {
                Log.Verbose("Word '{Word}' tokenized to {WordTokensCount} tokens:", word, wordTokens.Count);
                foreach (var t in wordTokens)
                {
                    Log.Verbose("  {L} ({S})", t, GetTokenText(t));
                }
            }
            
            // Add tokens up to maximum length (leaving room for SEP token)
            foreach (var token in wordTokens)
            {
                if (tokenPosition < maxTokens - 1)
                {
                    tokens.Add(token);
                    inputIds[tokenPosition] = token;
                    attentionMask[tokenPosition] = 1;
                    tokenPosition++;
                }
                else
                {
                    if (_debug) Log.Verbose("Reached max tokens, truncating");
                    break;
                }
            }
            
            if (tokenPosition >= maxTokens - 1)
            {
                break;
            }
        }
        
        // Add SEP token
        if (tokenPosition < maxTokens)
        {
            tokens.Add(_sepTokenId);
            inputIds[tokenPosition] = _sepTokenId;
            attentionMask[tokenPosition] = 1;
            tokenPosition++;
            
            if (_debug) Log.Verbose("Added SEP token: {SepToken} (ID: {SepTokenId})", _sepToken, _sepTokenId);
        }
        
        // Fill rest with padding
        for (int i = tokenPosition; i < maxTokens; i++)
        {
            inputIds[i] = _padTokenId;
            attentionMask[i] = 0; // Don't attend to padding tokens
        }
        
        if (_debug)
        {
            Log.Verbose("Final sequence (length {TokenPosition}, padded to {MaxTokens}):", tokenPosition, maxTokens);
            for (int i = 0; i < maxTokens; i++)
            {
                if (i < tokenPosition)
                {
                    Log.Verbose("  [{I}]: {InputId} ({S}) [Attention: {L}]", i, inputIds[i], GetTokenText(inputIds[i]), attentionMask[i]);
                }
                else
                {
                    Log.Verbose("  [{I}]: {InputId} (PAD) [Attention: {L}]", i, inputIds[i], attentionMask[i]);
                }
            }
        }
        
        return (inputIds, attentionMask, tokenTypeIds);
    }
    
    private string GetTokenText(long tokenId)
    {
        foreach (var pair in _vocab)
        {
            if (pair.Value == tokenId)
            {
                return pair.Key;
            }
        }
        return "UNKNOWN";
    }
    
    private List<long> TokenizeWord(string word)
    {
        // Check if the word is too long
        if (word.Length > _maxInputCharsPerWord)
        {
            return new List<long> { _unkTokenId };
        }
        
        // Check if the word is in the vocabulary
        if (_vocab.TryGetValue(word, out int wordId))
        {
            return new List<long> { wordId };
        }
        
        // Apply WordPiece tokenization
        var tokens = new List<long>();
        var isFirstSubToken = true;
        var remainingChars = word;
        
        while (remainingChars.Length > 0)
        {
            int endPos = remainingChars.Length;
            bool foundSubtoken = false;
            
            // Find the longest substring that's in the vocabulary
            while (endPos > 0 && !foundSubtoken)
            {
                string substr = remainingChars.Substring(0, endPos);
                
                // If not the first subtoken, add the continuing subword prefix
                if (!isFirstSubToken)
                {
                    substr = _continuingSubwordPrefix + substr;
                }
                
                if (_vocab.TryGetValue(substr, out int id))
                {
                    tokens.Add(id);
                    remainingChars = remainingChars.Substring(endPos);
                    isFirstSubToken = false;
                    foundSubtoken = true;
                }
                else
                {
                    endPos--;
                }
            }
            
            // If no subtokens found, add UNK and skip this word
            if (!foundSubtoken)
            {
                tokens.Add(_unkTokenId);
                break;
            }
        }
        
        return tokens;
    }
}