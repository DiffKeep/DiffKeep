# Search Architecture

Notes on the planned search system for AI-generated image libraries.

## Terminology: Vectors vs. Embeddings

These terms are used interchangeably in this context but have a subtle distinction:

- **Vector**: the mathematical object — an ordered list of floats representing a point in n-dimensional space.
- **Embedding**: a vector produced by a neural network that encodes semantic meaning. The defining property is that geometric proximity in the vector space corresponds to semantic similarity in the original domain.

Embeddings are vectors. The term "embedding" emphasizes that the vector was learned and carries meaning; "vector" emphasizes the data structure. In practice, "vector search" and "embedding search" mean the same thing.

---

## Search Modes

### 1. Full-Text Search

SQLite FTS5 with BM25 ranking. Searches `positive_prompt_text` and `negative_prompt_text` directly. Supports exact phrases, prefix search (`word*`), and boolean operators. Fast, zero extra dependency beyond what's already in use.

### 2. Semantic Prompt Search

Embeds the search query with a **text embedding model** and does KNN search against stored prompt embeddings. Finds images whose prompts are semantically similar to the query even with different vocabulary. Handles short query vs. long document well when using a model trained for asymmetric retrieval.

Prefix convention (Qwen3-VL-Embedding-2B):
- **Index time**: no prefix on document text
- **Query time**: prefix with `search_query: `

### 3. Visual Search (text query → images that look like the description)

Embeds the search query with a **VL text encoder** and does KNN search against stored **image embeddings**. Finds images that visually match the description regardless of what the original prompt said. Works because the VL model is trained so text and image share the same vector space.

Prefix convention (Qwen3-VL-Embedding-2B):
- **Index time (images)**: no prefix — pass empty string to mtmd
- **Query time (text)**: prefix with `search_query: `

This replaces the original CLIP-based design. See "Why Not CLIP" below.

### 4. Image Similarity Search

Encodes a query image with the **VL visual encoder** and does KNN search against stored image embeddings. Returns visually similar images.

### 5. Hybrid Search (FTS5 + semantic)

Combining FTS5 and vector search requires care because their scores are not comparable: BM25 is corpus-relative and has no fixed scale, while cosine distance is query-stable and bounded. **Do not attempt to normalize and combine scores directly.**

Use **Reciprocal Rank Fusion (RRF)** instead:

```
rrf_score(doc) = Σ  1 / (k + rank_in_list_i)
```

Run each search independently, assign rank positions (1, 2, 3...) within each result list, then accumulate `1/(60 + rank)` per document across all lists. Documents appearing in multiple lists naturally score higher. The constant `k=60` is the standard default; lower values (e.g. `k=20`) make rank differences matter more.

**Implementation:** do the merge in application code, not SQL. Run FTS5 (top-100), run KNN (top-100), merge into a `HashMap(image_id, f32)` accumulating RRF scores, sort descending.

### 6. Combined Visual + Semantic Search

Run semantic prompt search (mode 2) and visual search (mode 3) separately, then merge with RRF. No additional stored embeddings needed — the combination comes from merging at query time.

---

## Stored Embeddings Per Image

One model handles both vector types, so both live in the same 2048-dimensional space:

| Table | Encoder | Captures |
|-------|---------|----------|
| `positive_prompt_embeddings` | Qwen3-VL-Embedding-2B (text) | Semantic meaning of the prompt |
| `image_embeddings` | Qwen3-VL-Embedding-2B (vision) | Visual content of the image |

At query time, text queries are embedded with the text encoder (with `search_query:` prefix) and compared against whichever table is appropriate for the search mode. No separate model is needed for querying.

---

## Why Not CLIP

The original design called for CLIP or SigLIP for image embeddings and a separate text model for prompt embeddings. This is now superseded. Key reasons:

- **Qwen3-VL-Embedding-2B outperforms Qwen3-Embedding-8B on text search** (MRR=1.000 vs 0.975 on a 20-query benchmark) while being 4× smaller.
- **One model, one vector space** — text and image embeddings are directly comparable, enabling cross-modal search without format conversion.
- **CLIP has a hard 77-token limit** on text input; AI prompts regularly exceed this. The VL model handles up to 2048 tokens.
- **No modern CLIP/SigLIP has GGUF support** as of May 2026; adding PyTorch or ONNX is an unacceptable dependency for a desktop app.
- **Measured cross-modal retrieval** (text query → image) on 32 hand-annotated images with 19 queries: MRR=0.607, @1=53%, @5=63% using `search_query:` prefix on text and no prefix on images — solid results from a single unified model.

---

## Chosen Model: Qwen3-VL-Embedding-2B

**Files:**
- `Qwen.Qwen3-VL-Embedding-2B.Q8_0.gguf` — the language/embedding backbone
- `mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf` — the vision projector (loaded via mtmd)

**Specs:**
- Parameters: 2B
- Embedding dimensions: **2048**
- Text context: 2048 tokens (sufficient for all but the longest AI prompts)
- Image encoding: ~15–20ms per image on RTX 3090 via Vulkan GPU backend

**Prefix convention (confirmed by testing):**

| Use | Prefix |
|-----|--------|
| Indexing prompt text | *(none)* |
| Indexing images | *(none)* — empty string passed to mtmd |
| Querying (all modes) | `search_query: ` |

Using no prefix on queries drops MRR from 0.607 to 0.275. The mxbai prefix is load-bearing.

**GPU acceleration:**
Vulkan backend (`libggml-vulkan.so`) ships alongside the binary and is auto-selected at runtime via ggml's plugin loader. Works on NVIDIA, AMD, and Intel GPUs without per-vendor builds. CPU fallback is automatic if no Vulkan-capable GPU is present.

---

## Vector Storage

Both tables use **2048 dimensions** (Qwen3-VL-Embedding-2B output size). The earlier 1024/768 mismatch in the code is now resolved by this model choice.

sqlite-vec exact KNN is appropriate for a single-user desktop app at tens of thousands of images. Approximate KNN (usearch, faiss) adds complexity with no meaningful benefit at this scale.

---

## Benchmarked Models (May 2026)

### Text search quality (20-query benchmark, AI image prompts)

| Model | Best prefix | MRR | @1 | @3 | @5 |
|-------|-------------|-----|----|----|-----|
| **Qwen3-VL-Embedding-2B** | mxbai | **1.000** | **100%** | **100%** | **100%** |
| Qwen3-Embedding-8B | mxbai/qwen3/qwen3d | 0.975 | 95% | 100% | 100% |
| Qwen3-Embedding-0.6B | qwen3d | 0.858 | 75% | 100% | 100% |

### Cross-modal text→image retrieval (19 hand-annotated queries, 32-image corpus)

| txt prefix | img prefix | MRR | @1 | @3 | @5 |
|------------|------------|-----|----|----|-----|
| **mxbai** | **none** | **0.607** | **53%** | 63% | 63% |
| mxbai | doc | 0.585 | 42% | 68% | **74%** |
| qwen3 | none | 0.336 | 16% | 42% | 47% |
| none | none | 0.275 | 16% | 26% | 37% |

The `search_query:` prefix (`mxbai` mode) is essential — dropping it halves MRR. Image-side prefix is not needed.

---

## Open Questions

- Is the combined visual+semantic search (mode 6, RRF merge) meaningfully better than either alone for this image collection?
- What RRF `k` value works best for this collection size and query style?
- At what corpus size does sqlite-vec exact KNN become noticeably slow, and is it a concern in practice?
