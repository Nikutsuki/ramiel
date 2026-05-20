#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib"

echo "Building ReleaseFast..."
# Build locally first to get the full RUNPATH (includes nix store paths).
# -Dwayland=true is required to build the desktop_shell (bar + launcher).
zig build -Dwayland=true -Doptimize=ReleaseFast

# Capture the RUNPATH from the local build (has all nix store lib paths)
REF_BIN=$(find zig-out/bin -maxdepth 1 -type f | head -1)
ORIGINAL_RPATH=$(patchelf --print-rpath "$REF_BIN" 2>/dev/null || true)

# Now install to prefix
zig build -Dwayland=true -Doptimize=ReleaseFast -p "$PREFIX"

echo "Creating ffmpeg library symlinks..."
cd "$LIB_DIR"
for lib in libavcodec libavformat libavutil libswresample; do
    real=$(ls ${lib}.so.*.*.* 2>/dev/null | head -1)
    if [ -n "$real" ]; then
        soname=$(echo "$real" | sed 's/\.[0-9]*\.[0-9]*$//')
        ln -sf "$real" "$soname"
        ln -sf "$real" "${lib}.so"
    fi
done

echo "Patching binaries RPATH..."
# Build the RPATH: original nix paths + installed lib dir
# Replace the source-tree ffmpeg path with the installed lib dir
PATCHED_RPATH=$(echo "$ORIGINAL_RPATH" | tr ':' '\n' \
    | sed "s|.*/thirdparty/ffmpeg_linux_x64/lib|$LIB_DIR|" \
    | sed "s|.*/outputs/out/lib|$LIB_DIR|" \
    | awk '!seen[$0]++' \
    | paste -sd:)

if [ -z "$PATCHED_RPATH" ]; then
    PATCHED_RPATH="$LIB_DIR"
fi

for bin in "$BIN_DIR"/*; do
    if [ -f "$bin" ] && file "$bin" | grep -q "ELF.*executable"; then
        patchelf --force-rpath --set-rpath "$PATCHED_RPATH" "$bin"
        echo "  patched $(basename "$bin")"
    fi
done

echo "Done. Binaries installed to $BIN_DIR"
