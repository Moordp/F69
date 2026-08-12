#!/usr/bin/env bash
# Run the Layer-1 (dvui.testing) suite NATIVELY on the Windows VM.
#
# Why this exists: `zig build test` / `test-integration` only ever run on the
# build host, so every Windows-specific code path — launcher discovery, path
# handling, sandbox backend selection — was covered only by Linux runs. That is
# precisely where the user bug reports come from. The Layer-1 harness needs no
# display (dvui testing backend), so the cross-compiled test binary runs fine
# over SSH in the guest.
#
#   scripts/test-windows-vm.sh              build, ship, run, report
#   scripts/test-windows-vm.sh --no-build   reuse zig-out/test/test.exe
#
# Needs: the win11 entry in ~/VMs/vms.env, sshd running in the guest (see
# ~/VMs/win11-bootstrap.ps1). Exits non-zero when any test fails, so this can
# gate a release.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="$HOME/VMs"
# shellcheck disable=SC1091
source "$VMDIR/vms.env"

VM=win11
for e in "${VM_LIST[@]}"; do
  IFS=: read -r n ip u _pr d <<<"$e"
  [ "$n" = "$VM" ] && { IP=$ip; GU=$u; DOM=$d; }
done
[ -n "${IP:-}" ] || { echo "no '$VM' entry in vms.env" >&2; exit 2; }
_pv="VM_PASS_$VM"; PASS="${!_pv:-$VM_PASS}"

GUEST_DIR='C:\f69test'
OUT="$ROOT/zig-out/win-test-report.txt"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15)
# Prefer direct binaries: `timeout` must be able to signal the ssh process
# itself. Wrapping every call in `nix shell` swallows the signal — timeout
# kills the nix wrapper, the underlying ssh (and the guest process it is
# driving) lives on. Run the script under `nix shell nixpkgs#sshpass -c`
# to take this path; the nix-per-call variant remains as fallback.
if command -v sshpass >/dev/null 2>&1; then
  sh_()  { sshpass -p "$PASS" ssh  "${SSH_OPTS[@]}" "$GU@$IP" "$@"; }
  scp_() { sshpass -p "$PASS" scp  "${SSH_OPTS[@]}" "$@"; }
  sh_capped_() { timeout "$1" sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GU@$IP" "$2"; }
else
  sh_()  { nix shell nixpkgs#sshpass nixpkgs#openssh -c sshpass -p "$PASS" ssh  "${SSH_OPTS[@]}" "$GU@$IP" "$@"; }
  scp_() { nix shell nixpkgs#sshpass nixpkgs#openssh -c sshpass -p "$PASS" scp  "${SSH_OPTS[@]}" "$@"; }
  sh_capped_() { timeout "$1" nix shell nixpkgs#sshpass nixpkgs#openssh -c sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GU@$IP" "$2"; }
fi

# ---- 1. build -------------------------------------------------------------
if [ "${1:-}" != "--no-build" ]; then
  echo "== cross-compiling the Layer-1 suite for x86_64-windows =="
  # Same mingw prefix + pkg-config aliasing as build-windows.sh. Assumes that
  # script has been run at least once to populate /tmp/f69-win.
  W=/tmp/f69-win
  [ -d "$W/deps" ] || { echo "run scripts/build-windows.sh first (populates $W)" >&2; exit 2; }
  PKG_CONFIG_PATH="$W/pc:$W/deps/lib/pkgconfig" \
    zig build test-integration-exe -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
      --search-prefix "$W/deps" --search-prefix "$W/extra" || exit 1
fi
EXE="$ROOT/zig-out/test/test.exe"
[ -f "$EXE" ] || { echo "missing $EXE" >&2; exit 2; }

# ---- 2. ship --------------------------------------------------------------
echo "== shipping to $VM ($IP) =="
sh_ "if not exist $GUEST_DIR mkdir $GUEST_DIR" >/dev/null 2>&1
# Every exe in zig-out/test/: the Layer-1 suite (test.exe) plus the per-module
# unit suites (sandbox-test.exe, util-paths-test.exe, ...) — module unit tests
# can't ride inside the integration binary (Zig only collects root-module
# tests), so they ship as their own exes.
exe_count=0
for texe in "$ROOT"/zig-out/test/*.exe; do
  [ -f "$texe" ] || continue
  scp_ "$texe" "$GU@$IP:C:/f69test/" >/dev/null || exit 1
  exe_count=$((exe_count+1))
done
echo "   shipped $exe_count test exes"
# The suite links libarchive/openssl/etc, so the DLL closure has to sit beside
# the binary — SSH sessions cannot see the RDP \\tsclient share.
# Plain glob, not compgen: compgen is a bash builtin that is absent under the
# shell this runs in, and its failure silently skipped the DLL copy — the run
# then reported success while the guest binary could not start.
dll_count=0
for dll in "$ROOT"/zig-out/f69-windows/*.dll; do
  [ -f "$dll" ] || continue
  scp_ "$dll" "$GU@$IP:C:/f69test/" >/dev/null || exit 1
  dll_count=$((dll_count+1))
done
echo "   shipped $dll_count DLLs"
[ "$dll_count" -gt 0 ] || echo "   WARNING: no DLLs found — run scripts/package-windows.sh" >&2

# ---- 3. run ---------------------------------------------------------------
# Output goes to a file in the guest first: a long test run streamed straight
# down the SSH pipe gets truncated, and a partial report is worse than none.
# One report, sectioned per exe.
echo "== running natively in the guest =="
sh_ "cd $GUEST_DIR && del /q report.txt" >/dev/null 2>&1
rc_run=0
for texe in "$ROOT"/zig-out/test/*.exe; do
  base="$(basename "$texe")"
  echo "   running $base ($(date +%H:%M:%S), local 660s cap)"
  # LOCAL timeout, not a guest-side watchdog: a std.Io park must cost one
  # exe's cap, never the whole run. On expiry, kill the parked exe in the
  # guest explicitly and stamp the report so the parker is named.
  sh_capped_ 660 "cd $GUEST_DIR && echo ==== $base ==== >> report.txt && $base >> report.txt 2>&1" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    sh_ "taskkill /f /im $base" >/dev/null 2>&1
    sh_ "cd $GUEST_DIR && echo WATCHDOG: $base killed after 660s >> report.txt" >/dev/null 2>&1
    rc_run=124
  elif [ "$rc" -ne 0 ]; then
    rc_run=$rc
  fi
done

mkdir -p "$(dirname "$OUT")"
sh_ "type $GUEST_DIR\\report.txt" > "$OUT" 2>/dev/null

# ---- 4. report ------------------------------------------------------------
if [ ! -s "$OUT" ]; then
  echo "no report came back (guest exit $rc_run) — is sshd up? try: win-rdp.sh up" >&2
  exit 1
fi
echo "---- report: $OUT ----"
# Zig's test runner prints "N passed; M skipped; K failed." — or, when
# nothing skipped or failed, "All N tests passed." — one line per exe.
grep -E '^==== |[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed|All [0-9]+ tests passed|WATCHDOG' "$OUT"
fails=$(grep -cE '^[0-9]+/[0-9]+ .*(FAIL|error:)' "$OUT")
summaries=$(grep -cE '[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed|All [0-9]+ tests passed' "$OUT")
bad_summaries=$(grep -oE '[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed' "$OUT" | grep -cv '; 0 failed$')
if [ "$fails" -gt 0 ] || [ "$bad_summaries" -gt 0 ] || [ "$summaries" -lt "$exe_count" ]; then
  echo "FAILURES on Windows ($summaries/$exe_count suites reported, $bad_summaries with failures) — see $OUT" >&2
  grep -nE 'FAIL|error:' "$OUT" | head -20 >&2
  exit 1
fi
echo "Windows suites: PASS ($summaries/$exe_count exes clean)"
