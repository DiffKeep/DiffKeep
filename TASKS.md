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
- [x] macOS and Windows Zig code is now compiled from Linux: `zig build check
      -Dtarget=x86_64-windows-gnu` (whole app) and `zig build check-lib
      -Dtarget=aarch64-macos` (all but the SDL layer). Fixed what they found: the
      Windows/macOS drag sources' missing methods, Windows command-line parsing,
      sqlite's flags on macOS, and `SQLITE_TRANSIENT` on aarch64.
- [ ] Full Windows and macOS binaries can't be built from Linux: libvips (with glib)
      and FFmpeg are system libraries, and macOS SDL needs Apple's SDK. Build natively
      (Windows: MSYS2 mingw packages; macOS: Homebrew) and fix what that finds; the
      drag-and-drop C files (`lib/dnd/`) and app.zig's macOS paths are unchecked.
- [x] Prompts over 512 tokens got no prompt embedding (skipped, not truncated). They are
      now embedded with EmbeddingGemma's full window, split into at most 8 window-sized
      chunks and averaged past that (`embedPromptChunked`).
- [x] Strip A1111's `BREAK` keyword in `prompt_clean`. A standalone uppercase `BREAK`
      now becomes a separator; "break", "BREAKING" etc. are kept. Prompts already indexed
      keep their old embedding until rescanned (no re-embed migration).
- [x] `refreshCounts` ran five count queries on the UI thread after every change. It now
      only requests a load from `CountsLoader`, which runs them in the background.
- [x] dvui warned "processed closing window event but it has no open_flag" on shutdown.
      We close windows ourselves, so the close/quit events are now marked handled
      (`takeCloseEvents` in app.zig) and `Window.end` no longer sees them.
- [x] `zig build test` sometimes printed what looked like an integration-test failure
      ("run test diffkeep-integration-tests w" + "failed command:"). Not a failure: it
      exited 0. The build runner shows a passing step's stderr that way, and only when
      the tests actually ran (not cached). The stderr was warnings the tests trigger on
      purpose (now hidden per test with `quietWarnings`) and the viewer tests' missing
      fonts (they now install the style). A passing run prints nothing.

## Improvements

- [ ] Mixed text+image embeddings: one EmbeddingGemma 2 vector per image from prompt +
      pixels. Needs interleaved input support in TensorPencil first.
- [ ] Rebuild a harder labeled query set (outside the repo) and use it to calibrate the
      semantic / visual min-similarity cutoffs.
- [ ] Vector index: follow VECTOR_SEARCH_BENCH.md once the library outgrows brute force.
