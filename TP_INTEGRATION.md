# Integrating TensorPencil embedding encoders into DiffKeep

Handover for the DiffKeep-side agent. This explains how to call TensorPencil (TP)
as a native Zig library to produce the **text embedding vectors** DiffKeep's
semantic search needs, replacing the `onnxruntime` path (`src/onnx_embedder.zig`
+ `src/onnx_tokenizers.zig`) for the **text space**.

TP and DiffKeep are sibling checkouts (`../TensorPencil`, `../DiffKeep`), both on
**Zig 0.16.0**.

---

## 1. Status — what's ready

The **text embedding space** (Snowflake / EmbeddingGemma) is implemented natively
in TP and validated on CPU:

| Model | TP module | Tokenizer | Validated (cosine vs ONNX) |
|---|---|---|---|
| **Snowflake Arctic Embed M v2.0** (current DiffKeep model) | `models.embed_snowflake` | Unigram | **0.9999998** |
| **EmbeddingGemma 300m** (newer candidate) | `models.embed_gemma` | BPE | **0.999985** |

Both produce **L2-normalized 768-d `f32`** vectors, matching what DiffKeep stores
in its sqlite-vec `vec0` tables. Tokenizers are **bit-exact** vs HuggingFace
`tokenizers`, and the Snowflake tokenizer specifically reproduces DiffKeep's
existing `onnx_tokenizers.zig` output (verified 0 divergences on the test corpus),
so **switching to TP-Snowflake does not require re-embedding** the existing index.

**NOT yet done** (do not depend on these):
- The **image / cross-modal space** (SigLIP2 text + visual towers). DiffKeep must
  keep its ONNX SigLIP2 path for now. Only the text space moves to TP.
- **GPU backends** (CUDA/Vulkan) — CPU only today. Fast enough for indexing
  (300M/305M params, f32); GPU is a later TP milestone.
- **Batch** encode and a unified `tp.embed` façade — call the per-model API below.

---

## 2. Model files on disk

TP loads **safetensors + `tokenizer.json`** (it does not use ONNX). DiffKeep
currently ships the ONNX + tokenizers but **not** the safetensors, so add them to
the model directories (the `tokenizer.json` you already have is reused as-is):

- **Snowflake** dir must contain: `model.safetensors` (+ existing `tokenizer.json`).
  Source: `Snowflake/snowflake-arctic-embed-m-v2.0` (`model.safetensors`, ~1.2 GB f32,
  Apache-2.0).
- **EmbeddingGemma** dir must contain the sentence-transformers package:
  `model.safetensors`, `2_Dense/model.safetensors`, `3_Dense/model.safetensors`
  (+ its `tokenizer.json`). Source: `unsloth/embeddinggemma-300m` (ungated mirror of
  the gated `google/embeddinggemma-300m`; byte-identical, Gemma license).

Compute dtype is `f32` (the encoders are cheap; int8 is out of scope).

---

## 3. Build wiring

TP publishes a module named **`TensorPencil`** (package name `.TensorPencil`,
`build.zig.zon`).

In DiffKeep's `build.zig.zon`, add a path dependency:

```zig
.dependencies = .{
    // ... existing ...
    .TensorPencil = .{ .path = "../TensorPencil" },
},
```

In DiffKeep's `build.zig`, import the module into the exe/lib that does embedding:

```zig
const tp_dep = b.dependency("TensorPencil", .{
    .target = target,
    .optimize = optimize,
    // The f32 embedding path does NOT need ggml's quant kernels. Try disabling
    // ggml to avoid pulling in its C library + libc++:
    .ggml = false,
});
exe.root_module.addImport("TensorPencil", tp_dep.module("TensorPencil"));
```

> **ggml note:** ggml is an optional TP dependency (default **on**) providing fast
> AVX2 block-quant kernels. The embedding models compute in `f32`, whose GEMM path
> is native Zig, so `.ggml = false` should build and run fine and keeps DiffKeep's
> link simple. If the build complains, drop `.ggml = false` (default on) — then TP
> links `libggml` (needs `libc`/`libc++`), fetched automatically via `zig fetch`.

Build in **ReleaseFast** for indexing throughput (Debug f32 matmul is very slow).

---

## 4. API

Everything is reachable from `@import("TensorPencil")`:

- `tp.tokenizer.Tokenizer` — `initUnigramFromTokenizerJson` / `initGemma4FromTokenizerJson`,
  `.encode`, `.deinit`.
- `tp.models.embed_snowflake.Model` and `tp.models.embed_gemma.Model` —
  `.open(gpa, io, dir)`, `.embed(io, gpa, ids, out)`, `.deinit`. Both expose
  `embed_dim == 768`.

Key contracts:
- `Tokenizer.encode` emits **content ids only** — you add the model's frame
  (`<s>…</s>` or `<bos>…<eos>`).
- `Model.embed` takes the **framed** ids and writes an **L2-normalized 768-d** vector.
- Apply the model's **prompt prefix to the text before tokenizing** (asymmetric:
  queries vs documents).

### Prefixes and frame tokens (must match exactly)

| | Snowflake (A1) | EmbeddingGemma (A2) |
|---|---|---|
| query prefix | `"query: "` | `"task: search result \| query: "` |
| document prefix | *(none — raw text)* | `"title: none \| text: "` |
| frame | `<s>`=**0** … `</s>`=**2** | `<bos>`=**2** … `<eos>`=**1** |
| pooling (internal) | CLS (token 0) | mean over all tokens |

### End-to-end example (Snowflake)

```zig
const tp = @import("TensorPencil");

// Load once, reuse across all texts.
var tok_bytes = try std.Io.Dir.cwd().readFileAlloc(
    io, "Models/snowflake-arctic-embed-m-v2.0/tokenizer.json", gpa, .limited(64 << 20));
defer gpa.free(tok_bytes);
var tok = try tp.tokenizer.Tokenizer.initUnigramFromTokenizerJson(gpa, tok_bytes);
defer tok.deinit();

var model = try tp.models.embed_snowflake.Model.open(
    gpa, io, "Models/snowflake-arctic-embed-m-v2.0");
defer model.deinit();

// Per text:  vec is caller-owned, len 768, L2-normalized.
fn embedText(gpa: std.mem.Allocator, io: std.Io, tok: *const tp.tokenizer.Tokenizer,
             model: *const tp.models.embed_snowflake.Model,
             text: []const u8, is_query: bool) ![]f32 {
    // 1. prefix
    const prefixed = if (is_query)
        try std.fmt.allocPrint(gpa, "query: {s}", .{text})
    else
        try gpa.dupe(u8, text);
    defer gpa.free(prefixed);

    // 2. tokenize (content ids)
    var content: std.ArrayList(u32) = .empty;
    defer content.deinit(gpa);
    try tok.encode(gpa, prefixed, &content);

    // 3. frame: <s> … </s>
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    try ids.append(gpa, 0); // <s>
    try ids.appendSlice(gpa, content.items);
    try ids.append(gpa, 2); // </s>

    // 4. embed
    const vec = try gpa.alloc(f32, tp.models.embed_snowflake.embed_dim);
    try model.embed(io, gpa, ids.items, vec);
    return vec;
}
```

### EmbeddingGemma differences

Same shape, swap the module + prefixes + frame:

```zig
var tok = try tp.tokenizer.Tokenizer.initGemma4FromTokenizerJson(gpa, tok_bytes);
var model = try tp.models.embed_gemma.Model.open(gpa, io, "Models/embeddinggemma-300m");
// query prefix:    "task: search result | query: {text}"
// document prefix: "title: none | text: {text}"
// frame: <bos>=2 … <eos>=1  →  ids.append(2); ids.appendSlice(content); ids.append(1);
```

You need `io: std.Io` and a `gpa` (both already available from `main`/your worker).
Model + tokenizer loads are heavy (mmap ~1.2 GB); do them **once** and reuse. A
single `Model`/`Tokenizer` is `*const` for `embed`/`encode`, but is not internally
synchronized — use one per worker thread or guard with a mutex.

---

## 5. Where to wire it in DiffKeep

- Replace the text-embedding call sites currently going through
  `onnx_embedder.zig` / `onnx_tokenizers.zig` (in `scan.zig` for indexing and
  `search.zig` for queries) with the two steps above (tokenize+frame → `Model.embed`).
- Keep everything **below** the encoder unchanged: sqlite-vec storage, KNN/`MATCH`,
  Reciprocal-Rank-Fusion, min-similarity floors, FTS keyword mode.
- Keep the **SigLIP2** (image / cross-modal) path on ONNX for now — TP does not
  cover it yet.
- Once the text space is on TP and stable, `onnxruntime` is still needed only for
  SigLIP2; the text-only ONNX models (`snowflake…/onnx`, `nomic…/onnx`) can be dropped.

---

## 6. Choosing the model (A1 vs A2)

This is DiffKeep's call, via its `search_quality_corpus` / `test_search_quality`
eval:
- **Snowflake (A1)** — the current model; TP reproduces its exact tokenization, so
  it drops in with **no re-embed**. Safest.
- **EmbeddingGemma (A2)** — newer, higher MTEB, Matryoshka-truncatable (768→512/256/128).
  Switching means a **one-time full re-embed** of the text index (different embedding
  space) and using the A2 prefixes above.

TP can carry **both** (they share the tokenizer/encoder infra), so you can A/B them
on the eval corpus before committing.

---

## 7. Limitations / gotchas

- **CPU only** today. Fine for indexing; build ReleaseFast.
- **EmbeddingGemma asserts sequence length ≤ 512 tokens** (post-framing). Its local
  layers use a 512 sliding window that TP currently runs as full attention (correct
  for ≤512). Truncate longer inputs, or file a TP request for the long-doc path.
  Snowflake's own limit is 512 tokens (XLM-R), so cap inputs at 512 either way.
- **Output is already L2-normalized** — do not normalize again (DiffKeep's
  `sim = 1 - d²/2` under sqlite-vec L2 relies on unit vectors).
- **No batch API** yet — loop per text (threads for parallelism).
- Parity floor is cosine ≥ 0.999 vs the reference ONNX; measured is ≥ 0.99998, so
  retrieval quality is effectively identical. Re-run DiffKeep's eval after the swap
  to confirm no regression.
