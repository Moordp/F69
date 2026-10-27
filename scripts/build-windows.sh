#!/usr/bin/env bash
# Cross-compile f69 for x86_64-windows. Builds the mingw-w64 C-lib prefix (nix/windows-deps.nix),
# wires pkg-config name-aliases + import-lib (.a→.dll.a) symlinks that zig's windows lib search
# needs, then runs `zig build -Dtarget=x86_64-windows-gnu`.  Output: zig-out/bin/f69.exe (+ DLLs to bundle).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=/tmp/f69-win; mkdir -p "$W"
echo "== building mingw C-lib prefix =="
# Pure: windows-deps.nix pins nixpkgs (nix/pinned.nix) and sets
# allowUnsupportedSystem in-expression, so no --impure / channel needed.
nix build -f "$ROOT/nix/windows-deps.nix" -o "$W/deps"
# pkg-config name aliases (linkSystemLibrary name -> real .pc filename)
mkdir -p "$W/pc"; cp -f "$W"/deps/lib/pkgconfig/*.pc "$W/pc/" 2>/dev/null || true
alias_pc(){ if [ -f "$W/pc/$2" ]; then cp -f "$W/pc/$2" "$W/pc/$1"; fi; }
alias_pc archive.pc libarchive.pc; alias_pc z.pc zlib.pc; alias_pc bz2.pc bzip2.pc
alias_pc lzma.pc liblzma.pc; alias_pc zstd.pc libzstd.pc; alias_pc lz4.pc liblz4.pc
alias_pc xml2.pc libxml-2.0.pc; alias_pc avif.pc libavif.pc
# Newer nixpkgs' mingw zlib ships libz.a but no zlib.pc; write one so `linkSystemLibrary("z")` resolves.
if [ ! -f "$W/pc/z.pc" ]; then
  printf 'prefix=%s\nName: zlib\nDescription: zlib\nVersion: 1\nLibs: -L${prefix}/lib -lz\nCflags: -I${prefix}/include\n' "$W/deps" > "$W/pc/z.pc"
fi
# import-lib aliases: zig searches lib<name>.a but mingw ships lib<name>.dll.a
mkdir -p "$W/extra/lib"; cd "$W/extra/lib"
for n in archive bz2 lzma zstd lz4 nettle hogweed; do
  L=$(PKG_CONFIG_PATH="$W/pc" pkg-config --libs-only-L "$n" 2>/dev/null | tr ' ' '\n' | grep -oE '/nix/store/[^ ]+/lib' | head -1) || true
  imp=$(ls "$L"/lib$n*.dll.a 2>/dev/null | head -1) || true
  [ -n "${imp:-}" ] && ln -sf "$imp" "lib$n.a"
done
echo "== zig build x86_64-windows-gnu =="
cd "$ROOT"
# ReleaseFast (NOT ReleaseSafe): ReleaseSafe enables _FORTIFY_SOURCE → MinGW fortified <wchar.h>
# inlines → zig 0.16 translate-c "unused local constant" failure in every @cImport. See build.zig.
PKG_CONFIG_PATH="$W/pc:$W/deps/lib/pkgconfig" \
  zig build -Dtarget=x86_64-windows-gnu -Doptimize="${1:-ReleaseFast}" \
  --search-prefix "$W/deps" --search-prefix "$W/extra"
echo "== done: $(ls -la "$ROOT"/zig-out/bin/f69.exe 2>/dev/null || echo 'no exe yet') =="
