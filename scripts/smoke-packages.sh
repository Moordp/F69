#!/usr/bin/env bash
#
# smoke-packages.sh — run smoke-package.sh for every built artifact, each
# inside the distro container its package format targets.
#
# This is the local mirror of the CI "smoke" job: point it at a directory of
# already-built artifacts (what the release/build jobs upload, or a directory
# you filled with `zig build deb|rpm|aur|portable|portable-slim`) and it spins
# up the matching base image per artifact, installs it, and runs the fixed
# smoke battery from smoke-package.sh — all headless, no GPU needed.
#
# Format → base image:
#   *debian*.deb          → debian:bookworm-slim   (apt resolves deps)
#   *fedora*.rpm          → fedora:latest          (dnf resolves deps)
#   *arch*.pkg.tar.zst    → archlinux:latest       (pacman resolves deps)
#   *portable*.tar.gz     → debian:bookworm-slim   (bundles its own glibc —
#                                                    OLD base proves it runs)
#   *slim*.tar.gz         → ubuntu:latest          (uses SYSTEM glibc, so its
#                                                    floor is the build host's)
#   *windows*.zip         → debian:bookworm-slim   (PE DLL-closure check via
#                                                    objdump; no Wine needed)
#
# NOTE on slim: the slim bundle links the system glibc, so it only runs on a
# host whose glibc is >= the machine that BUILT it. If you built the bundle on
# a bleeding-edge host (e.g. NixOS unstable, glibc 2.42), a glibc-version FAIL
# in ubuntu:latest is EXPECTED and correct — it's telling you that host's slim
# bundle won't run on Ubuntu. Build slim on an older base, or ship the
# portable-full bundle (glibc-independent) for wide reach.
#
# Usage:
#   scripts/smoke-packages.sh [artifact-dir]     # default: ./artifacts
#   F69_ENGINE=docker scripts/smoke-packages.sh  # force docker over podman
#
# Exit status: 0 = every container passed, 1 = at least one failed or errored.
# The nix build is checked separately (`nix build .#f69`) and isn't a package
# artifact, so it's out of scope here — CI covers it in its own job.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART_DIR="${1:-$ROOT/artifacts}"

if [ ! -d "$ART_DIR" ]; then
    echo "smoke-packages: artifact dir not found: $ART_DIR" >&2
    echo "  build some first (zig build deb|rpm|aur|portable|portable-slim)" >&2
    echo "  or pass a dir of downloaded release artifacts." >&2
    exit 2
fi

# Container engine: prefer podman (rootless on NixOS), fall back to docker.
ENGINE="${F69_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else
        echo "smoke-packages: need podman or docker (nix profile add nixpkgs#podman)" >&2
        exit 2
    fi
fi
echo "smoke-packages: engine=$ENGINE  artifacts=$ART_DIR"

# Runtime libs the slim bundle needs on a bare Debian base (DEPS.md), minus
# the -dev suffix. Native packages pull their own deps in, so this list is
# only used for the slim tarball.
SLIM_DEPS="libwayland-client0 libxkbcommon0 libdecor-0-0 libavif15 libdav1d6 \
libsqlite3-0 libssl3 libarchive13 libdbus-1-3 liblzma5 libbz2-1.0 zlib1g \
libxml2 libzstd1 liblz4-1 libnettle8 libacl1 libvulkan1 mesa-vulkan-drivers"

# Map an artifact filename to "image|prep-command". prep installs whatever the
# smoke test needs beyond the artifact itself (coreutils for `timeout`, ldd,
# and — for slim — the runtime libs). The .deb/.rpm/.pkg install step inside
# smoke-package.sh resolves the package's own declared deps.
image_and_prep() {
    case "$1" in
        *debian*.deb)
            echo "debian:bookworm-slim|apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates" ;;
        *fedora*.rpm)
            echo "fedora:latest|dnf install -y -q findutils >/dev/null" ;;
        *arch*.pkg.tar.zst)
            echo "archlinux:latest|pacman -Sy --noconfirm --needed >/dev/null" ;;
        *slim*.tar.gz)
            # ubuntu:latest, not bookworm — slim needs glibc >= its build
            # host, which usually exceeds Debian stable's.
            echo "ubuntu:latest|apt-get update -qq && apt-get install -y -qq --no-install-recommends $SLIM_DEPS" ;;
        *portable*.tar.gz)
            # Portable bundles its libs + glibc loader; a bare base + the
            # Vulkan loader (dlopen'd, not bundled) is all it needs.
            echo "debian:bookworm-slim|apt-get update -qq && apt-get install -y -qq --no-install-recommends libvulkan1" ;;
        *windows*.zip)
            # PE DLL-closure check needs objdump (binutils reads PE) + unzip.
            # Wine is optional; skip it here to keep the container light.
            echo "debian:bookworm-slim|apt-get update -qq && apt-get install -y -qq --no-install-recommends binutils unzip" ;;
        *) echo "" ;;
    esac
}

# Collect artifacts we know how to test.
shopt -s nullglob
ARTIFACTS=()
for f in "$ART_DIR"/*.deb "$ART_DIR"/*.rpm "$ART_DIR"/*.pkg.tar.zst "$ART_DIR"/*.tar.gz "$ART_DIR"/*.zip; do
    ARTIFACTS+=("$f")
done
if [ "${#ARTIFACTS[@]}" -eq 0 ]; then
    echo "smoke-packages: no testable artifacts in $ART_DIR" >&2
    exit 2
fi

TOTAL=0
FAILED=0
FAILED_NAMES=""
for art in "${ARTIFACTS[@]}"; do
    name="$(basename "$art")"
    spec="$(image_and_prep "$name")"
    if [ -z "$spec" ]; then
        echo "-- skip $name (no image mapping)"
        continue
    fi
    image="${spec%%|*}"
    prep="${spec#*|}"
    TOTAL=$((TOTAL + 1))

    echo
    echo "########################################################"
    echo "# $name  →  $image"
    echo "########################################################"

    # Mount the repo read-only so the container can run smoke-package.sh, plus
    # the artifact dir. Everything the test writes goes to the container's
    # own /tmp (thrown away with the container). --pull=missing avoids a slow
    # re-pull each run.
    "$ENGINE" run --rm \
        --pull=missing \
        -v "$ROOT:/work:ro" \
        -v "$ART_DIR:/art:ro" \
        -w /tmp \
        "$image" \
        bash -c "set -e; $prep >/dev/null 2>&1 || $prep; cp /art/'$name' /tmp/ && bash /work/scripts/smoke-package.sh /tmp/'$name'"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        FAILED=$((FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES $name"
    fi
done

# ----- Nix: build the flake package + smoke its result prefix (host, no
# container — needs the local nix + store). Best-effort: the flake build is
# impure (Zig fetch), so a build miss is reported, not a hard error.
if command -v nix >/dev/null 2>&1; then
    echo
    echo "########################################################"
    echo "# nix build .#f69  →  result/"
    echo "########################################################"
    TOTAL=$((TOTAL + 1))
    if nix build "$ROOT#f69" --impure --out-link "$ROOT/result-smoke" 2>&1 | tail -3; [ -e "$ROOT/result-smoke/bin/f69" ]; then
        VER=$(awk -F'"' '/\.version = / { print $2; exit }' "$ROOT/build.zig.zon")
        F69_EXPECT_VERSION="$VER" bash "$ROOT/scripts/smoke-package.sh" "$(readlink -f "$ROOT/result-smoke")" || {
            FAILED=$((FAILED + 1)); FAILED_NAMES="$FAILED_NAMES nix"; }
        rm -f "$ROOT/result-smoke"
    else
        echo "nix build produced no result (impure-fetch story) — counting as failed"
        FAILED=$((FAILED + 1)); FAILED_NAMES="$FAILED_NAMES nix"
    fi
else
    echo "-- skip nix leg (nix not installed)"
fi

echo
echo "========================================================"
if [ "$FAILED" -eq 0 ]; then
    echo "smoke-packages: all $TOTAL package(s) passed"
else
    echo "smoke-packages: $FAILED/$TOTAL failed:$FAILED_NAMES"
fi
echo "========================================================"
[ "$FAILED" -eq 0 ]
