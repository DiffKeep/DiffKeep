#!/usr/bin/env bash
# Zip one release build: the executable, the libraries installed beside it (the
# DLLs and vips' loader modules on Windows, the .so files on Linux) and the license
# texts. Dev tools and debug info stay out.
# usage: tools/package_release.sh <name> <install prefix>   ->  dist/diffkeep-<name>.zip
set -euo pipefail
name=$1
prefix=$2
stage="dist/stage/diffkeep-$name"
rm -rf "$stage" "dist/diffkeep-$name.zip"
mkdir -p "$stage"
cp -r "$prefix/bin/." "$stage/"
rm -f "$stage"/*.pdb "$stage"/video_probe "$stage"/video_probe.exe
# ELF keeps its DWARF inline; drop it but keep the symbols, so a crash still names functions.
for f in "$stage"/*; do
  if [ -f "$f" ] && head -c 4 "$f" | grep -q $'\x7fELF'; then strip --strip-debug "$f"; fi
done
cp README.md tools/release/BUNDLED_LIBRARIES.txt "$stage/"
if [ -d "$prefix/share/licenses" ]; then cp -r "$prefix/share/licenses" "$stage/licenses"; fi
(cd dist/stage && zip -qr "../diffkeep-$name.zip" "diffkeep-$name")
echo "dist/diffkeep-$name.zip: $(du -h "dist/diffkeep-$name.zip" | cut -f1)"
