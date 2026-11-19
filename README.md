# DiffKeep

DiffKeep is a desktop library manager for AI-generated images and videos. Add your output folders as libraries and it indexes everything in them, reads the generation metadata (ComfyUI workflows, Automatic1111/Forge parameters, [TensorPencil](https://github.com/qskousen/TensorPencil)), and lets you browse, filter and search (text, semantic, visual).

DiffKeep is free and open source under the [MIT License](LICENSE).

> This is a ground-up rewrite in [Zig](https://ziglang.org). The original C# version lives on the [`legacy-csharp`](https://github.com/DiffKeep/DiffKeep/tree/legacy-csharp) branch and its releases (v0.4.6 and earlier) are still on the releases page.

## Features

- **Auto-synced libraries.** Add folders as libraries; DiffKeep scans them in the background and updates as files are added, changed, or removed.
- **Generation metadata.** Prompts, models, samplers and the full ComfyUI workflow, parsed from the metadata.
- **Four kinds of search:**
  - full-text search over prompts and metadata;
  - semantic search of prompt meaning;
  - visual search by what the image shows;
  - combined, merging the semantic and visual results.
- **Filters and favorites.** Narrow any view by library, folder, generator, type, model, and more; track favorites.
- **Videos and animations.** Full support for videos and animated images with frame-by-frame controls.
- **Trash and duplicates.** Deleting moves files to DiffKeep's trash (automatically empties after 30 days). Find and clean up duplicates.
- **Local only.** Everything runs on your machine; nothing is uploaded. No telemetry or tracking of any kind. Embeddings run on the CPU, or on the GPU through Vulkan or CUDA.

Search models are not bundled: download them from Settings if you want semantic or visual search. EmbeddingGemma is subject to the [Gemma Terms of Use](https://ai.google.dev/gemma/terms); SigLIP 2 is Apache-2.0.

## Building

DiffKeep builds with **Zig 0.17.0**. Release builds for Linux and Windows (x86-64) are on the [releases page](https://github.com/DiffKeep/DiffKeep/releases). macOS is planned but not available yet.

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

A release build includes its own libvips and FFmpeg instead of the system's: `zig build -Dbundle-libs` on Linux; always enabled for Windows, which cross-compiles from Linux (`zig build -Dtarget=x86_64-windows-gnu`).

`zig build run -- --config <dir>` uses `<dir>/DiffKeep.cfg` instead of the default config, allowing portable use.

The embedding encoders come from [TensorPencil](https://github.com/qskousen/TensorPencil).

## Contributing

Issues and pull requests are welcome. Run `zig build test` before sending a change. If you work on DiffKeep and TensorPencil together, enable the repo's pre-commit hook, which checks that `build.zig.zon` pins TensorPencil to a published commit rather than a local path:

```bash
git config core.hooksPath tools/hooks
```

## License

DiffKeep is released under the MIT License; see [LICENSE](LICENSE). Third-party software and fonts it includes are listed, with their licenses, in [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt) and in the app's About dialog.
