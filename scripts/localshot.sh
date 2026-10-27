#!/usr/bin/env bash
# Local visual check WITHOUT the VM. Runs the real f69 binary inside a
# headless `cage` wlroots compositor (off-screen — no window on your desktop),
# pointed at a throwaway F69_DATA_DIR seeded with one rich game, and grabs a
# screenshot with grim. Needs Vulkan (lavapipe is fine).
#
#   scripts/localshot.sh [screen] [out.png]
#     screen : detail | library    (default detail)
#     out    : output PNG path      (default /tmp/f69-localshot/shot.png)
#
# Iterate loop:  zig build portable && scripts/localshot.sh detail && <Read the png>
set -uo pipefail
cd "$(dirname "$0")/.."

SCREEN="${1:-detail}"
OUT="${2:-/tmp/f69-localshot/shot.png}"
DATA="/tmp/f69-localshot/data"
BIN="$PWD/zig-out/bin"
TD="$PWD/src/testkit/testdata"
LOG="/tmp/f69-localshot/f69.log"

[ -x "$BIN/f69" ] || { echo "build first: zig build portable"; exit 1; }
rm -rf /tmp/f69-localshot; mkdir -p "$DATA/covers" "$(dirname "$OUT")"

# Default: headless (off-screen). VIS=1 → cage opens a real window in your
# niri session so you can watch it. grim runs INSIDE cage either way, so the
# PNG is always just f69 (no surrounding desktop).
[ -z "${VIS:-}" ] && export WLR_BACKENDS=headless

run() { nix shell nixpkgs#cage nixpkgs#grim nixpkgs#sqlite -c "$@"; }

# 1. Create the DB schema: launch once headless, let migrations run, kill.
echo "[localshot] creating schema…"
F69_DATA_DIR="$DATA" run bash -c \
  "cage -- bash -c '$BIN/run.sh >$LOG 2>&1 & sleep 4; kill %1 2>/dev/null' " >/dev/null 2>&1 || true

DB="$DATA/f69.db"
[ -f "$DB" ] || { echo "[localshot] DB not created — f69 log:"; tail -20 "$LOG" 2>/dev/null; exit 1; }

# 2. Seed one rich game: portrait cover, 3 screenshots, 3 installs.
echo "[localshot] seeding…"
cp "$TD/cover.png" "$DATA/covers/101"
cp "$TD/shot1.png" "$DATA/covers/102"   # landscape cover (list-view fit check)
# list/grid read the downscaled `<id>.t` thumbs, not the full cover
cp "$TD/cover.png" "$DATA/covers/101.t"
cp "$TD/shot1.png" "$DATA/covers/102.t"
cp "$TD/shot1.png" "$DATA/covers/101.s1"
cp "$TD/shot1.png" "$DATA/covers/101.s2"
cp "$TD/shot1.png" "$DATA/covers/101.s3"
T=$(date +%s)
run sqlite3 "$DB" "
INSERT OR REPLACE INTO games(f95_thread_id,name,developer,rating,vote_count,completion_status,engine,latest_version,created_at,screenshots_json)
 VALUES (101,'Eternal Dusk','Moonlit Studios',4.6,1200,'in_progress','renpy','0.9.0',$T,'[\"s1\",\"s2\",\"s3\"]');
INSERT OR REPLACE INTO games(f95_thread_id,name,developer,rating,vote_count,completion_status,engine,latest_version,created_at)
 VALUES (102,'Wide Cover Game','Studio B',3.5,80,'in_progress','rpgmmv','1.2',$T);
INSERT OR REPLACE INTO installs(id,game_thread_id,version,install_path,recipe_id,installed_at) VALUES
 ('inst-0900',101,'0.9.0','$DATA/g090','manual',$T),
 ('inst-0820',101,'0.8.2','$DATA/g082','manual',$T),
 ('inst-0700',101,'0.7.0','$DATA/g070','manual',$T);
" || { echo "[localshot] seed failed"; exit 1; }
mkdir -p "$DATA/g090" "$DATA/g082" "$DATA/g070"

# 3. Launch headless, navigate to the screen, screenshot, kill.
#    F69_OPEN_SCREEN/THREAD let the app boot straight onto the target view.
echo "[localshot] rendering $SCREEN…"
F69_DATA_DIR="$DATA" F69_OPEN_SCREEN="$SCREEN" F69_OPEN_THREAD=101 \
run bash -c \
  "cage -- bash -c '$BIN/run.sh >>$LOG 2>&1 & sleep 6; grim \"$OUT\"; kill %1 2>/dev/null' " >/dev/null 2>&1

[ -s "$OUT" ] && echo "[localshot] wrote $OUT" || { echo "[localshot] no screenshot — f69 log:"; tail -25 "$LOG"; exit 1; }
