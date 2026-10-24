# VECTOR_SEARCH_BENCH.md: does DiffKeep need a vector index?

Question: is brute-force KNN fast enough at the library sizes DiffKeep will see, or is
an index (graph or partitioned) worth its complexity? Answer it with measurements, not
assumptions. Building an index is the LAST step and only happens if the numbers call for it.

Encoders are TensorPencil's job; storage and search are DiffKeep's. A planned encoder
switch to EmbeddingGemma 2 (one 768-d space for text and images, truncatable to 256 or 128
dims) is in TensorPencil's `DIFFKEEP_GEMMA2.md`. It changes the vector count and width this
plan has to cover.

## Where things stand

- `src/db.zig`: two `vec0` tables (`image_embeddings`, `positive_prompt_embeddings`),
  `float[768]`, default L2 metric on unit vectors. sqlite-vec is vendored at
  `v0.1.7-alpha.2` (`lib/sqlite-vec`), and its `MATCH ... AND k = ?` is a full scan.
- `searchByEmbedding` asks for `2 * limit` from KNN, then looks up each row in `images`
  one at a time to drop trashed ones. `searchCombined` runs both tables and merges them
  with Reciprocal Rank Fusion (k=60).
- Real library on this box: 50,586 images, i.e. ~155 MB of f32 vectors per table and
  ~310 MB for both.
- Nothing measures query latency today. `test_search_quality` and `test_cross_modal`
  measure quality only.

Known issue to fix whatever the results say: the trash filter runs AFTER KNN with a fixed
2x over-fetch, so a library with many trashed near-duplicates returns fewer than `limit`
results. A filter applied during the scan (see below) fixes this; so does looping until
`limit` is filled.

## What to measure

For every candidate, at every size:

| metric | why |
|---|---|
| query latency, p50 and p99, warm | what typing in the search box feels like |
| query latency, cold (first query after open) | the first search after launch |
| recall@10 and recall@100 vs exact f32 | what an approximation costs |
| end-to-end search time (encode + KNN + trash filter + RRF) | the number the user actually feels |
| resident memory | it is a desktop app beside other things |
| on-disk size | the db is already 705 MB |
| insert cost per vector, and a 10k batch | scanning a new folder |
| delete/trash cost | trash is soft-delete with a 30-day purge |
| open/load time | blocks the first search |

Budget to judge against (assumed, revisit): KNN under 10 ms p99 at the target size, so
the encoder (a few ms on CPU) plus KNN stays well under one frame of typing debounce.

## Sizes

10k, 50k (today), 200k, 1M, 5M. 5M is a generous upper bound for a personal library.

Data: a READ-ONLY copy of the real db (never open the live one in write mode) for 50k.
Bigger sizes must keep real structure: random Gaussian vectors have no clusters, which
makes every ANN index look worse and brute force look the same, so they produce a wrong
answer. Options, in order:
1. Real vectors from a larger image set run through the same encoder (best, costs encode time).
2. Real vectors plus small per-copy perturbations (cheap, keeps clusters, overstates
   near-duplicates; label it).
3. A public embedding set of the same width (LAION/CLIP-style) for an outside check.

Queries: the `search_quality_corpus` queries plus a held-out sample of real vectors
(image-to-image search). Ground truth is exact f32 brute force.

## Candidates, cheapest first

Stop climbing as soon as one meets the budget at the target size.

1. **Current**: sqlite-vec `vec0 float[768]`, as shipped. This is the baseline.
2. **sqlite-vec quantized**: `int8[768]` and `bit[768]` columns (`vec_quantize_int8`,
   `vec_quantize_binary` exist in this version), with an f32 rerank of the top k * 4.
   No new code outside SQL.
3. **Flat scan in Zig over a packed array**: all vectors in one contiguous mmapped or
   in-memory buffer loaded from SQLite at open, SIMD dot products, a top-k heap, trash
   as a bitmap checked during the scan. Variants: f32, int8, 1-bit plus rerank.
   Multithreaded over chunks.
4. **Fewer dims**: run 3 at 256-d (Matryoshka truncation, only with an encoder that
   supports it, e.g. EmbeddingGemma 2) and with RaBitQ-style random rotation + scalar
   codes (training-free, so nothing to retrain as the library grows).
5. **Graph index**: HNSW (or Vamana) over the codes from 4, with in-place deletes.
   Only if 3/4 miss the budget at a size DiffKeep will realistically reach.

Expected (assumed, this is what the benchmark is for): 3 at f32 should scan 50k in a few
ms and 1M in tens of ms; 3+4 should handle 5M near the budget. If so, the answer is "no
index", with candidate 3 replacing vec0 for speed and for filtering during the scan.

## How to run it

- A `zig build vec_bench -- <db copy> [flags]` tool beside the other `test_*` tools,
  ReleaseFast, printing one row per candidate and size.
- Each candidate goes behind one interface (`build`, `insert`, `delete`, `search(q, k,
  allowed_bitmap)`), so the harness and the recall math are shared.
- Run every condition 3-5x first to see run-to-run noise, then compare candidates by
  interleaving them in one process, not across separate invocations.
- Warm and cold separately; for cold, drop the page cache only on a copy, never by
  touching other processes.
- Cap memory: build big sizes in streaming chunks and check RSS. Never load an unbounded
  multi-GB set on the shared desktop box.

## Decision rules

- Candidate 1 meets the budget at 1M: keep vec0, fix only the trash filter.
- 2 or 3 meets it at the target size: adopt the cheapest, no index.
- Only 5 meets it: build it, with SQLite as the source of truth. Each vector row carries a
  rising `seq`; the index file stores the last `seq` it applied and replays newer rows on
  open, so it can be rebuilt from SQLite at any time and needs no transactions of its own.
- Record each result with its receipt (size, candidate, p50/p99, recall). A "not needed"
  conclusion needs the measured number that shows it.

## Background reading (if step 5 is reached)

Indexes that take inserts and deletes without a rebuild:
- IP-DiskANN, arXiv 2502.13826: in-place graph deletes, no consolidation pass.
- Quake, OSDI '25: adaptive multi-level partitions, automatic nprobe from a recall target.
- OdinANN, FAST '26: direct insert into an on-disk graph.
- SPFresh, SOSP '23: local rebalancing of partitioned indexes.
- UBIS (arXiv 2602.00563), Slipstream (arXiv 2606.02992): streaming-update work.

Faster graph search: PAG, ICML '26, arXiv 2603.06660 (up to 5x HNSW QPS, online inserts).

Training-free codes: Extended RaBitQ (arXiv 2409.09913, github
VectorDB-NTU/RaBitQ-Library) and TurboQuant (arXiv 2504.19874), same family.

Filtered search: arXiv 2602.11443 finds partitioned indexes beat HNSW when a filter
removes most rows.

All figures in these papers are the authors' own; none reproduced.
