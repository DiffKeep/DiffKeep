List of tasks that need doing. Mark as completed when done; user will remove once verified.


## Fixes

- [x] Searches and view changes could overwrite each other (a search landing after
      switching to Trash replaced the Trash view). Searches now go through the grid's
      own background load, so the latest request always wins; a late embedding never
      changes the view.
- [x] An image added by a scan while a view load was running could vanish until the
      next reload. It is now re-added when the load lands.
- [x] Vector search returned fewer than `limit` results when trashed images were among
      the nearest neighbours. It now widens the KNN until the limit is filled or the
      similarity floor is reached.
- [ ] macOS and Windows code is not compiled by a Linux build; cross-compile under Zig
      0.17 (`-Dtarget=aarch64-macos`, `-Dtarget=x86_64-windows`) and fix what breaks.
- [x] Prompts over 512 tokens got no prompt embedding (skipped, not truncated). They are
      now embedded with EmbeddingGemma's full window, split into at most 8 window-sized
      chunks and averaged past that (`embedPromptChunked`).
- [x] Strip A1111's `BREAK` keyword in `prompt_clean`. A standalone uppercase `BREAK`
      now becomes a separator; "break", "BREAKING" etc. are kept. Prompts already indexed
      keep their old embedding until rescanned (no re-embed migration).
- [x] `refreshCounts` ran five count queries on the UI thread after every change. It now
      only requests a load from `CountsLoader`, which runs them in the background.
- [ ] dvui warns "processed closing window event but it has no open_flag" on shutdown.

## Improvements

- [ ] Mixed text+image embeddings: one EmbeddingGemma 2 vector per image from prompt +
      pixels. Needs interleaved input support in TensorPencil first.
- [ ] Rebuild a harder labeled query set (outside the repo) and use it to calibrate the
      semantic / visual min-similarity cutoffs.
- [ ] Vector index: follow VECTOR_SEARCH_BENCH.md once the library outgrows brute force.
