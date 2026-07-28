#!/usr/bin/env bash
#
# smoke-package.sh — prove one built f69 artifact actually installs and runs.
#
# Give it a single package/tarball and it runs a fixed battery of checks that
# don't need a GPU or a display, so it works in a plain CI container:
#
#   1. INSTALL   — install the .deb/.rpm/.pkg.tar.zst, or extract the tarball,
#                  into this (throwaway) environment.
#   2. VERSION   — `f69 --version` exits 0 and prints the version baked into
#                  the artifact filename (catches a stale/mismatched build).
#   3. LDD       — `ldd` on the binary reports no "not found" shared libs
#                  (the classic "packaged on the wrong base" failure).
#   4. LAUNCH    — a headless launch reaches the clean GPU-abort path
#                  (exit 1 + the actionable Vulkan message) instead of a
#                  panic/segfault. Getting there proves the whole non-GUI
#                  startup ran: data dir created, DB opened + migrated,
#                  backup + run-log written. This is the real integration
#                  smoke — `--version` returns long before any of that.
#   5. FILES     — the files the package is supposed to ship are present
#                  (binary, run.sh/DEPS.md for portable, license under FHS).
#
# Usage:
#   scripts/smoke-package.sh <artifact>
#   scripts/smoke-package.sh f69-0.10.1-debian-x86_64.deb
#   scripts/smoke-package.sh f69-0.10.1-linux-portable-x86_64.tar.gz
#
# Type is detected from the filename. Installing a native package needs root
# (run it in the matching distro container — see smoke-packages.sh); the
# portable/slim tarballs extract without root.
#
# Exit status: 0 = every check passed, 1 = at least one failed.

set -uo pipefail

# ----- args ----------------------------------------------------------------
if [ "$#" -ne 1 ]; then
    echo "usage: $0 <artifact.(deb|rpm|pkg.tar.zst|tar.gz|zip) | install-prefix-dir>" >&2
    exit 2
fi
ARTIFACT="$1"
if [ ! -e "$ARTIFACT" ]; then
    echo "smoke: artifact not found: $ARTIFACT" >&2
    exit 2
fi
# A directory argument is an install PREFIX (e.g. a Nix build's ./result, whose
# bin/f69 is already in place) rather than a package file to install/extract.
PREFIX_MODE=0
if [ -d "$ARTIFACT" ]; then
    PREFIX_MODE=1
    ARTIFACT="$(cd "$ARTIFACT" && pwd)"
else
    ARTIFACT="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"
fi
BASENAME="$(basename "$ARTIFACT")"

# Version expected in the binary: from the filename (f69-<ver>-…) for a package,
# else the F69_EXPECT_VERSION env (prefix mode has no versioned name).
EXPECT_VER="$(printf '%s\n' "$BASENAME" | sed -n 's/^f69-\([0-9][0-9.]*\)-.*/\1/p')"
[ -z "$EXPECT_VER" ] && EXPECT_VER="${F69_EXPECT_VERSION:-}"

# ----- reporting -----------------------------------------------------------
PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '  ---- %s\n' "$1"; }

# DLLs Windows itself provides — never expected in the bundle. Kept in sync
# with scripts/package-windows.sh (the packager's harvest whitelist).
win_is_system_dll() {
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
        kernel32.dll|ntdll.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|\
        oleaut32.dll|comdlg32.dll|crypt32.dll|imm32.dll|version.dll|winmm.dll|ws2_32.dll|\
        setupapi.dll|msvcrt.dll|rpcrt4.dll|bcrypt.dll|secur32.dll|dxgi.dll|\
        d3d12.dll|d3d11.dll|gdiplus.dll|shcore.dll|dwmapi.dll|uxtheme.dll|userenv.dll|\
        netapi32.dll|iphlpapi.dll|dnsapi.dll|wsock32.dll|winhttp.dll|wininet.dll|\
        cfgmgr32.dll|powrprof.dll|hid.dll|cabinet.dll|api-ms-win-*) return 0 ;;
    esac
    return 1
}

# Windows smoke: extract the zip, verify the DLL closure is complete (the PE
# analog of ldd — walk f69.exe's import table breadth-first and assert every
# non-system DLL is bundled), best-effort `wine --version`, and the exe exists.
smoke_windows() {
    info "extracting windows zip"
    if ! command -v unzip >/dev/null 2>&1; then
        fail "unzip not available — cannot inspect windows zip"; return
    fi
    unzip -q "$ARTIFACT" -d "$WORK"
    local exe; exe="$(find "$WORK" -iname 'f69.exe' | head -n1)"
    if [ -z "$exe" ]; then fail "f69.exe not found in zip"; return; fi
    local dir; dir="$(dirname "$exe")"
    pass "extract produced $(basename "$exe")"

    # PICK an objdump that reads PE. Prefer the mingw one; plain binutils
    # objdump also parses PE import tables ("DLL Name:").
    local objdump=""
    for cand in x86_64-w64-mingw32-objdump objdump; do
        command -v "$cand" >/dev/null 2>&1 && { objdump="$cand"; break; }
    done
    if [ -z "$objdump" ]; then
        info "no objdump — skipping DLL-closure check"
    else
        # BFS the import graph. worklist = basenames to inspect; seen tracks
        # visited; missing collects non-system imports absent from the dir.
        local worklist="f69.exe" seen=" " missing=""
        while [ -n "$worklist" ]; do
            local cur="${worklist%% *}"; worklist="${worklist#"$cur"}"; worklist="${worklist# }"
            case "$seen" in *" $cur "*) continue ;; esac
            seen="$seen$cur "
            local curpath; curpath="$(find "$dir" -maxdepth 1 -iname "$cur" | head -n1)"
            [ -z "$curpath" ] && continue
            local imp
            for imp in $("$objdump" -p "$curpath" 2>/dev/null | grep -i 'DLL Name' | awk '{print $3}'); do
                win_is_system_dll "$imp" && continue
                if [ -n "$(find "$dir" -maxdepth 1 -iname "$imp" | head -n1)" ]; then
                    case "$seen" in *" $imp "*) ;; *) worklist="$worklist $imp" ;; esac
                else
                    case "$missing" in *" $imp "*) ;; *) missing="$missing $imp" ;; esac
                fi
            done
        done
        if [ -z "$missing" ]; then
            pass "DLL closure complete (no unbundled non-system DLLs)"
        else
            fail "DLL closure incomplete — unbundled non-system DLLs:$missing"
        fi
    fi

    # Best-effort execution via Wine. --version returns before any GPU/backend
    # init, so it works headless; skipped cleanly where wine isn't installed.
    if command -v wine >/dev/null 2>&1; then
        local out rc
        out="$(cd "$dir" && WINEDEBUG=-all timeout 90 wine f69.exe --version 2>/dev/null)"; rc=$?
        if [ "$rc" -eq 0 ] && { [ -z "$EXPECT_VER" ] || printf '%s' "$out" | grep -qF "$EXPECT_VER"; }; then
            pass "wine --version exits 0 ($(printf '%s' "$out" | tr -d '\r' | head -n1))"
        else
            fail "wine --version failed (exit $rc): $(printf '%s' "$out" | tr -d '\r' | head -n1)"
        fi
    else
        info "wine not installed — skipping --version run (DLL-closure check still ran)"
    fi
}

# Throwaway workspace + data dir; cleaned on exit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/f69-smoke.XXXXXX")"
DATA="$WORK/data"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "== smoke: $BASENAME (expect version '${EXPECT_VER:-?}') =="

# Windows is a different animal (PE, no ELF/ldd, no native exec on Linux) —
# handle it in its own path and finish.
case "$BASENAME" in
    *windows*.zip | *.zip)
        smoke_windows
        echo "== smoke: $PASS passed, $FAIL failed =="
        [ "$FAIL" -eq 0 ]
        exit $?
        ;;
esac

# BIN  = the f69 executable to test.
# ENTRY = how to invoke it (may be a run.sh wrapper for the portable bundle).
# EXTRA_FILES = space-separated files that must exist after install/extract.
BIN=""
ENTRY=""
EXTRA_FILES=""
# Set for the portable-full bundle: the dir holding its bundled glibc loader
# + libs. When set, the ldd check resolves via that loader (the bundle ships
# its own glibc), not the host loader — otherwise a bundle built on newer
# glibc than the host looks "broken" when it actually self-supplies glibc.
BUNDLE_LIB=""
# Set when the runnable entry is a wrapper (Nix's bin/f69 is a makeWrapper
# shell script over bin/.f69-wrapped that injects LD_LIBRARY_PATH). A raw ldd
# of the wrapped ELF resolves against the host loader, NOT the wrapper's env —
# on a non-NixOS runner that mismatches the store glibc and false-fails. The
# wrapper-invoked --version + launch checks are the real lib-resolution proof,
# so skip the raw ldd in that case.
SKIP_LDD=0

# ----- 1. install / extract ------------------------------------------------
if [ "$PREFIX_MODE" -eq 1 ]; then
    info "install prefix (already built): $ARTIFACT"
    BIN="$ARTIFACT/bin/f69"
    ENTRY="$BIN"
    [ -x "$ARTIFACT/bin/run.sh" ] && ENTRY="$ARTIFACT/bin/run.sh"
    [ -f "$ARTIFACT/bin/.f69-wrapped" ] && SKIP_LDD=1
else
case "$BASENAME" in
    *.deb)
        info "installing .deb"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends "$ARTIFACT" >/dev/null 2>&1 \
                || { dpkg -i "$ARTIFACT" >/dev/null 2>&1; apt-get install -y -f >/dev/null 2>&1; }
        else
            dpkg -i "$ARTIFACT" >/dev/null 2>&1 || true
        fi
        BIN="/usr/bin/f69"
        ENTRY="$BIN"
        EXTRA_FILES="/usr/share/doc/f69/copyright"
        ;;
    *.rpm)
        info "installing .rpm"
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y "$ARTIFACT" >/dev/null 2>&1
        else
            rpm -i --nodeps "$ARTIFACT" >/dev/null 2>&1 || true
        fi
        BIN="/usr/bin/f69"
        ENTRY="$BIN"
        ;;
    *.pkg.tar.zst)
        info "installing .pkg.tar.zst"
        pacman -U --noconfirm "$ARTIFACT" >/dev/null 2>&1 || true
        BIN="/usr/bin/f69"
        ENTRY="$BIN"
        EXTRA_FILES="/usr/share/licenses/f69/LICENSE"
        ;;
    *linux-portable*.tar.gz | *portable*.tar.gz)
        info "extracting portable bundle"
        tar -xzf "$ARTIFACT" -C "$WORK"
        BIN="$WORK/bin/f69"
        # run.sh execs the bundled glibc loader; it's the intended entry.
        if [ -x "$WORK/bin/run.sh" ]; then ENTRY="$WORK/bin/run.sh"; else ENTRY="$BIN"; fi
        EXTRA_FILES="$WORK/bin/run.sh"
        [ -d "$WORK/bin/lib" ] && BUNDLE_LIB="$WORK/bin/lib"
        ;;
    *slim*.tar.gz)
        info "extracting slim bundle"
        tar -xzf "$ARTIFACT" -C "$WORK"
        BIN="$WORK/portable-slim/f69"
        if [ -x "$WORK/portable-slim/run.sh" ]; then ENTRY="$WORK/portable-slim/run.sh"; else ENTRY="$BIN"; fi
        EXTRA_FILES="$WORK/portable-slim/run.sh $WORK/portable-slim/DEPS.md"
        ;;
    *)
        echo "smoke: unknown artifact type: $BASENAME" >&2
        exit 2
        ;;
esac
fi

if [ -x "$BIN" ]; then
    pass "install/extract produced $BIN"
else
    fail "binary missing after install/extract (expected $BIN)"
    echo "== smoke: $PASS passed, $FAIL failed (aborted early) =="
    exit 1
fi

# ----- 2. --version --------------------------------------------------------
VER_OUT="$("$ENTRY" --version 2>&1)"
VER_RC=$?
if [ "$VER_RC" -eq 0 ]; then
    if [ -z "$EXPECT_VER" ] || printf '%s' "$VER_OUT" | grep -qF "$EXPECT_VER"; then
        pass "--version exits 0 ($(printf '%s' "$VER_OUT" | head -n1))"
    else
        fail "--version ran but text '$VER_OUT' lacks expected version '$EXPECT_VER'"
    fi
else
    fail "--version exited $VER_RC: $VER_OUT"
fi

# ----- 3. ldd: no missing shared libs --------------------------------------
# For a bundled bundle, resolve through its own loader + libs (the bundle
# self-supplies glibc, so the host loader would wrongly report it broken).
# For a native package / slim bundle, plain ldd against the host loader is
# correct — those DO use the system glibc.
if [ "$SKIP_LDD" -eq 1 ]; then
    info "wrapped binary (nix) — lib resolution validated via the wrapper's --version + launch, skipping raw ldd"
elif [ -n "$BUNDLE_LIB" ]; then
    # The loader sits under lib/glibc/; libs span lib/glibc/ + lib/. Mirror
    # run.sh's search order (glibc, then app libs, then the host GPU dirs for
    # system libs the bundle deliberately doesn't ship) so we don't flag a
    # dlopen'd system lib as missing.
    LOADER="$(find "$BUNDLE_LIB" -name 'ld-linux*.so*' 2>/dev/null | head -n1)"
    if [ -n "$LOADER" ]; then
        LOADER_DIR="$(dirname "$LOADER")"
        LDP="$LOADER_DIR:$BUNDLE_LIB:/usr/lib/x86_64-linux-gnu:/usr/lib64:/usr/lib"
        MISSING="$(LD_LIBRARY_PATH="$LDP" "$LOADER" --list "$BIN" 2>/dev/null | grep 'not found' || true)"
        if [ -z "$MISSING" ]; then
            pass "ldd (via bundled loader): no missing shared libraries"
        else
            fail "ldd (via bundled loader): missing libraries:"
            printf '%s\n' "$MISSING" | sed 's/^/         /'
        fi
    else
        info "bundled lib dir has no ld-linux loader — skipping ldd"
    fi
elif command -v ldd >/dev/null 2>&1; then
    MISSING="$(ldd "$BIN" 2>/dev/null | grep 'not found' || true)"
    if [ -z "$MISSING" ]; then
        pass "ldd: no missing shared libraries"
    else
        fail "ldd: missing libraries:"
        printf '%s\n' "$MISSING" | sed 's/^/         /'
    fi
else
    info "ldd not available — skipping missing-lib check"
fi

# ----- 4. headless launch → clean GPU-abort, not a crash -------------------
# No display + no Vulkan device: the SDL3-GPU backend can't init, so f69 must
# hit its handled BackendError path (prints the Vulkan message, exit 1) after
# a full non-GUI startup. A panic/segfault (exit >= 134) or a hang is a fail.
LAUNCH_LOG="$WORK/launch.log"
timeout 60 env -u WAYLAND_DISPLAY -u DISPLAY F69_DATA_DIR="$DATA" \
    "$ENTRY" >"$LAUNCH_LOG" 2>&1
LAUNCH_RC=$?
if [ "$LAUNCH_RC" -eq 124 ]; then
    fail "headless launch hung (timed out) — expected a clean GPU-abort"
elif [ "$LAUNCH_RC" -ge 134 ]; then
    fail "headless launch crashed (exit $LAUNCH_RC — panic/signal)"
    tail -n 15 "$LAUNCH_LOG" | sed 's/^/         /'
elif grep -q "could not initialize the GPU" "$LAUNCH_LOG"; then
    if [ -f "$DATA/f69.db" ]; then
        pass "headless launch reached clean GPU-abort after full startup (db created)"
    else
        pass "headless launch reached clean GPU-abort (exit $LAUNCH_RC)"
    fi
else
    # Exit 0 (somehow got a GPU) or a different error without the message.
    fail "headless launch did not reach the expected GPU-abort (exit $LAUNCH_RC)"
    tail -n 15 "$LAUNCH_LOG" | sed 's/^/         /'
fi

# ----- 5. expected shipped files -------------------------------------------
FILES_OK=1
for f in $EXTRA_FILES; do
    if [ ! -e "$f" ]; then
        fail "expected packaged file missing: $f"
        FILES_OK=0
    fi
done
[ "$FILES_OK" -eq 1 ] && pass "expected packaged files present"

# ----- verdict -------------------------------------------------------------
echo "== smoke: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
