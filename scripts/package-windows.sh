#!/usr/bin/env bash
# Package the Windows build into a self-contained, redistributable folder (+ zip).
# Resolves the EXACT DLL closure of zig-out/bin/f69.exe by walking the PE import
# table (objdump -p) breadth-first over the mingw dep prefix, so only the DLLs the
# binary actually needs get bundled — no dead weight (nettle/gmp/iconv aren't used
# by the Windows libarchive chain, which links openssl + zlib1 instead).
#
# Prereq: run scripts/build-windows.sh first (produces zig-out/bin/f69.exe + the
# mingw dep prefix at /tmp/f69-win/deps).  Output: zig-out/f69-windows/ + .zip
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=/tmp/f69-win
EXE="$ROOT/zig-out/bin/f69.exe"
DEPS_BIN="$W/deps/bin"
OUT="$ROOT/zig-out/f69-windows"

[ -f "$EXE" ] || { echo "error: $EXE missing — run scripts/build-windows.sh first" >&2; exit 1; }
[ -d "$DEPS_BIN" ] || { echo "error: $DEPS_BIN missing — run scripts/build-windows.sh first" >&2; exit 1; }

OBJDUMP=$(nix shell -f "$ROOT/nix/windows-tools.nix" mingwBinutils -c bash -c 'command -v x86_64-w64-mingw32-objdump')
[ -n "$OBJDUMP" ] || { echo "error: could not resolve mingw objdump" >&2; exit 1; }

# DLLs Windows itself provides — never bundle these.
is_sys(){ case "${1,,}" in
  kernel32.dll|ntdll.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|\
  oleaut32.dll|comdlg32.dll|crypt32.dll|imm32.dll|version.dll|winmm.dll|ws2_32.dll|\
  setupapi.dll|msvcrt.dll|rpcrt4.dll|bcrypt.dll|secur32.dll|api-ms-win-*|dxgi.dll|\
  d3d12.dll|d3d11.dll|gdiplus.dll|shcore.dll|dwmapi.dll|uxtheme.dll|userenv.dll|\
  netapi32.dll|iphlpapi.dll|dnsapi.dll|wsock32.dll|winhttp.dll|wininet.dll|\
  cfgmgr32.dll|powrprof.dll|hid.dll|cabinet.dll) return 0;; esac; return 1; }

# BFS the import graph, collecting the non-system DLLs found in the dep prefix.
declare -A seen; queue=("$EXE"); closure=()
while [ ${#queue[@]} -gt 0 ]; do
  cur="${queue[0]}"; queue=("${queue[@]:1}")
  for dll in $("$OBJDUMP" -p "$cur" 2>/dev/null | grep -i "DLL Name" | awk '{print $3}'); do
    lc="${dll,,}"; is_sys "$dll" && continue; [ -n "${seen[$lc]:-}" ] && continue; seen[$lc]=1
    if [ -f "$DEPS_BIN/$dll" ]; then closure+=("$DEPS_BIN/$dll"); queue+=("$DEPS_BIN/$dll")
    else echo "warning: unbundled non-system DLL: $dll (referenced by $(basename "$cur"))" >&2; fi
  done
done

rm -rf "$OUT"; mkdir -p "$OUT"
cp -f "$EXE" "$OUT/"
for d in "${closure[@]}"; do cp -fL "$d" "$OUT/"; done

# ---- aria2c.exe -------------------------------------------------------------
# Bundle the official aria2 build: downloads are dead without it — the app's
# resolveAria2Path probes for aria2c.exe NEXT TO f69.exe first, and a clean
# Windows machine has no aria2 on PATH (gap found 2026-08-12: Linux portable
# bundles aria2c, the Windows zip never did). Pinned upstream release, sha256
# verified, cached under /tmp/f69-win so packaging stays offline after the
# first run.
ARIA2_VER=1.37.0
ARIA2_ZIP="$W/aria2/aria2.zip"
ARIA2_URL="https://github.com/aria2/aria2/releases/download/release-${ARIA2_VER}/aria2-${ARIA2_VER}-win-64bit-build1.zip"
ARIA2_SHA256=67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288
mkdir -p "$W/aria2"
[ -f "$ARIA2_ZIP" ] || curl -sL -o "$ARIA2_ZIP" "$ARIA2_URL"
echo "$ARIA2_SHA256  $ARIA2_ZIP" | sha256sum -c - >/dev/null || {
  echo "error: aria2 zip sha256 mismatch — refusing to bundle" >&2; exit 1; }
python3 - "$ARIA2_ZIP" "$OUT" <<'PY'
import sys, zipfile, pathlib
z, out = zipfile.ZipFile(sys.argv[1]), pathlib.Path(sys.argv[2])
exe = next(n for n in z.namelist() if n.endswith("aria2c.exe"))
(out / "aria2c.exe").write_bytes(z.read(exe))
lic = next((n for n in z.namelist() if n.endswith("COPYING")), None)
if lic: (out / "aria2-COPYING.txt").write_bytes(z.read(lic))
PY
echo "== bundled aria2c.exe ${ARIA2_VER} =="

cat > "$OUT/README.txt" <<'TXT'
f69 — Windows build
===================
Run f69.exe in place; the bundled .dll files must stay alongside it.

Data location: %APPDATA%\f69  (database, covers, library)

Downloads: the bundled aria2c.exe must stay alongside f69.exe (it is the
download engine; aria2 is GPLv2, see aria2-COPYING.txt).

Sandboxing (optional): install Sandboxie-Plus (https://sandboxie-plus.com).
f69 auto-detects Start.exe under %ProgramFiles%\Sandboxie-Plus\ (or classic
%ProgramFiles%\Sandboxie\). To point at a portable/custom install instead,
set the F69_SANDBOXIE_PATH environment variable to the full path of Start.exe.
Without Sandboxie, games launch unsandboxed.
TXT

echo "== bundled (${#closure[@]} DLLs) =="; ls -1 "$OUT"
ZIP="$ROOT/zig-out/f69-windows.zip"; rm -f "$ZIP"
( cd "$ROOT/zig-out" && nix shell -f "$ROOT/nix/windows-tools.nix" zip -c zip -qr "$ZIP" f69-windows )
echo "== done: $ZIP ($(du -h "$ZIP" | cut -f1)) =="
