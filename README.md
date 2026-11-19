# DiffKeep

DiffKeep is a desktop library manager for AI-generated images and videos. Point it
at your output folders and it indexes everything in them, reads the generation
metadata (ComfyUI workflows, Automatic1111/Forge parameters, TensorPencil), and
lets you browse, filter and search the lot.

DiffKeep is free and open source under the [MIT License](LICENSE).

> This is a ground-up rewrite in [Zig](https://ziglang.org). The original C#
> version lives on the [`legacy-csharp`](https://github.com/DiffKeep/DiffKeep/tree/legacy-csharp) branch and its
> releases (v0.4.6 and earlier) are still on the releases page.

## Features

- **Libraries that stay in sync.** Add folders as libraries; DiffKeep scans them
  in the background and watches them for new, changed and deleted files.
- **Generation metadata.** Prompts, models, samplers and the full ComfyUI
  workflow, parsed from the image's own metadata, plus which tool made it.
- **Four kinds of search:**
  - full-text search over prompts and metadata;
  - semantic search by prompt meaning (EmbeddingGemma 300M);
  - visual search by what the image shows (SigLIP 2);
  - combined, merging the semantic and visual results.
- **Filters and favorites.** Narrow any view by library, folder, generator and
  more; mark favorites.
- **Videos and animations.** Animated images and videos play in the grid and
  the viewer.
- **Trash and duplicates.** Deleting moves files to DiffKeep's trash (restorable,
  purged after 30 days); find and clear duplicates.
- **Local only.** Everything, including the search models, runs on your machine;
  nothing is uploaded. Embeddings run on the CPU, or on the GPU through Vulkan or
  CUDA.

Search models are not bundled: download them from Settings when you want
semantic or visual search. EmbeddingGemma is subject to the
[Gemma Terms of Use](https://ai.google.dev/gemma/terms); SigLIP 2 is Apache-2.0.

## Building

DiffKeep builds with **Zig 0.17.0**. Linux is the supported build today; Windows
and macOS code compiles but full binaries aren't produced yet.

System libraries (Debian/Ubuntu package names):

```bash
sudo apt install libvips-dev libavformat-dev libavcodec-dev libavutil-dev \
  libswscale-dev libswresample-dev libx11-dev libxi-dev libwayland-dev
```

Then:

```bash
zig build run        # build and run
zig build            # build only (silent on success)
zig build test       # unit and integration tests
```

`zig build run -- --config <dir>` uses `<dir>/DiffKeep.cfg` instead of the
default config, for a throwaway setup.

The embedding encoders come from
[TensorPencil](https://github.com/qskousen/TensorPencil), fetched by the build
like the other Zig dependencies.

## Contributing

Issues and pull requests are welcome. Run `zig build test` before sending a
change. If you work on DiffKeep and TensorPencil together, enable the repo's
pre-commit hook, which checks that `build.zig.zon` pins TensorPencil to a
published commit rather than a local path:

```bash
git config core.hooksPath tools/hooks
```

## License

DiffKeep is released under the MIT License; see [LICENSE](LICENSE). Third-party
software and fonts it includes are listed, with their licenses, in
[THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt) and in the app's About
dialog.
